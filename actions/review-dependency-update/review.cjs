const { writeFile } = require("node:fs/promises");
const path = require("node:path");

const marker = "<!-- dependency-review -->";
const sourceFile =
  /\.(?:[cm]?[jt]sx?|py|css|html|json|toml|ya?ml|lock|txt|md|ini|cfg)$/i;
const unsafePath =
  /(^|\/)(?:\.git|\.claude|\.agents|node_modules|\.venv|dist|vendor)(\/|$)|(^|\/)(?:CLAUDE\.md|AGENTS\.md|\.mcp\.json|\.env(?:\..*)?)$/;

const ciLabels = {
  success: "成功",
  failure: "失敗",
  in_progress: "実行中",
  undetected: "未検出（未設定または未開始）",
  incomplete: "未完了（中断・スキップなど）",
  unavailable: "未確認（CI 情報を取得できない）",
};

function selectTarget({ repo, pr, expected }) {
  const fullName = `${repo.owner}/${repo.repo}`;
  return pr?.state === "open" &&
    pr.number === expected.number &&
    pr.head?.ref?.startsWith("dependabot/") &&
    pr.user?.login === "dependabot[bot]" &&
    pr.head?.repo?.full_name === fullName &&
    pr.base?.repo?.full_name === fullName &&
    pr.head.sha === expected.head &&
    pr.base.sha === expected.base
    ? pr
    : null;
}

function eventTarget(context) {
  if (
    context.eventName !== "pull_request_target" ||
    !["opened", "synchronize", "reopened"].includes(context.payload.action)
  ) {
    throw new Error("PR の作成・更新・再オープンからのみ実行できます。");
  }
  const pr = context.payload.pull_request;
  if (!Number.isSafeInteger(pr?.number) || !pr.head?.sha || !pr.base?.sha) {
    throw new Error("PR のイベント情報が不正です。");
  }
  return { number: pr.number, head: pr.head.sha, base: pr.base.sha };
}

async function getTarget({ github, context }) {
  const expected = eventTarget(context);
  const { data: pr } = await github.rest.pulls.get({
    ...context.repo,
    pull_number: expected.number,
  });
  return selectTarget({ repo: context.repo, pr, expected });
}

async function collectCi({ github, repo, pr }) {
  const result = {
    checkedAt: new Date().toISOString(),
    state: "undetected",
    runs: [],
    limitation:
      "資料収集時点の GitHub Actions の状態。完了待ち・再取得・完了後の自動更新は行わない。未検出は未設定か未開始かを区別できない。",
  };
  let runs;
  try {
    runs = await github.paginate(github.rest.actions.listWorkflowRunsForRepo, {
      ...repo,
      head_sha: pr.head.sha,
      event: "pull_request",
      per_page: 100,
    });
  } catch {
    result.state = "unavailable";
    return result;
  }
  const latest = new Map();
  for (const run of runs.sort((a, b) => b.id - a.id)) {
    if (
      run.event !== "pull_request" ||
      run.head_sha !== pr.head.sha ||
      run.repository?.full_name !== `${repo.owner}/${repo.repo}` ||
      !run.pull_requests?.some(
        (link) =>
          link.number === pr.number &&
          link.head.sha === pr.head.sha &&
          link.base.sha === pr.base.sha,
      )
    )
      continue;
    const key = run.workflow_id ?? run.path;
    if (!latest.has(key)) latest.set(key, run);
  }
  const candidates = [...latest.values()];
  if (!candidates.length) return result;
  if (
    candidates.some((run) =>
      ["failure", "timed_out", "action_required", "startup_failure"].includes(
        run.conclusion,
      ),
    )
  )
    result.state = "failure";
  else if (candidates.some((run) => run.status !== "completed"))
    result.state = "in_progress";
  else if (candidates.every((run) => run.conclusion === "success"))
    result.state = "success";
  else result.state = "incomplete";
  result.omittedRunCount = Math.max(0, candidates.length - 10);
  let logCount = 0;
  for (const run of candidates.slice(0, 10)) {
    const detail = {
      id: run.id,
      name: run.name,
      url: run.html_url,
      status: run.status,
      conclusion: run.conclusion,
      jobs: [],
      failureLogs: [],
    };
    result.runs.push(detail);
    let jobs;
    try {
      jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
        ...repo,
        run_id: run.id,
        per_page: 100,
        filter: "latest",
      });
    } catch {
      detail.jobsUnavailable = true;
      continue;
    }
    detail.jobs = jobs.map((job) => ({
      name: job.name,
      url: job.html_url,
      status: job.status,
      conclusion: job.conclusion,
      steps: (job.steps || []).map((step) => ({
        name: step.name,
        conclusion: step.conclusion,
      })),
    }));
    for (const job of jobs.filter((job) => job.conclusion === "failure")) {
      if (logCount >= 3) break;
      logCount += 1;
      try {
        const { data } =
          await github.rest.actions.downloadJobLogsForWorkflowRun({
            ...repo,
            job_id: job.id,
          });
        if (typeof data !== "string")
          throw new Error("ログ本文を取得できませんでした。");
        detail.failureLogs.push({
          job: job.name,
          tail: data.slice(-30000),
          truncated: data.length > 30000,
        });
      } catch {
        detail.failureLogs.push({ job: job.name, unavailable: true });
      }
    }
  }
  return result;
}

async function snapshot({ github, repo, sha, changed }) {
  const { data } = await github.rest.git.getTree({
    ...repo,
    tree_sha: sha,
    recursive: "1",
  });
  const result = {
    sha,
    files: [],
    omitted: [],
    truncatedTree: Boolean(data.truncated),
  };
  const entries = data.tree
    .filter((entry) => entry.type === "blob")
    .sort(
      (a, b) =>
        Number(changed.has(b.path)) - Number(changed.has(a.path)) ||
        a.path.localeCompare(b.path),
    );
  let bytes = 0;
  for (const entry of entries) {
    if (
      !sourceFile.test(entry.path) ||
      unsafePath.test(entry.path) ||
      entry.mode === "120000" ||
      entry.size > 200000 ||
      result.files.length >= 120 ||
      bytes >= 2000000
    ) {
      result.omitted.push(entry.path);
      continue;
    }
    const { data: blob } = await github.rest.git.getBlob({
      ...repo,
      file_sha: entry.sha,
    });
    if (blob.encoding !== "base64") {
      result.omitted.push(entry.path);
      continue;
    }
    const content = Buffer.from(blob.content, "base64").toString("utf8");
    if (
      content.includes("\0") ||
      bytes + Buffer.byteLength(content) > 2000000
    ) {
      result.omitted.push(entry.path);
      continue;
    }
    bytes += Buffer.byteLength(content);
    result.files.push({ path: entry.path, lines: content.split("\n") });
  }
  return result;
}

async function collect({ github, repo, pr }) {
  const files = await github.paginate(github.rest.pulls.listFiles, {
    ...repo,
    pull_number: pr.number,
    per_page: 100,
  });
  const changed = new Set(files.map((file) => file.filename));
  const before = await snapshot({ github, repo, sha: pr.base.sha, changed });
  const after = await snapshot({ github, repo, sha: pr.head.sha, changed });
  const ci = await collectCi({ github, repo, pr });
  // PR 本文のリンクだけで security update と断定しない。公開 Advisory は補足資料として取得する。
  const advisoryIds = [
    ...new Set(
      (pr.body || "").match(
        /GHSA-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}/gi,
      ) || [],
    ),
  ];
  const advisories = [];
  for (const ghsa_id of advisoryIds.slice(0, 10)) {
    try {
      advisories.push(
        (await github.request("GET /advisories/{ghsa_id}", { ghsa_id })).data,
      );
    } catch {
      advisories.push({ ghsa_id, unavailable: true });
    }
  }
  return {
    repository: `${repo.owner}/${repo.repo}`,
    number: pr.number,
    title: pr.title,
    body: pr.body,
    before,
    after,
    changes: files.map((file) => ({
      path: file.filename,
      previousPath: file.previous_filename,
      status: file.status,
      patch: file.patch ?? null,
    })),
    ci,
    advisories,
    limitations: [
      "公開 Advisory が見つからない場合は脆弱性なしと判断しない。",
      "省略ファイル・切り詰められたツリーがある場合、未調査範囲をコメントに明記する。",
      "チェックしているのは PR の base/head SHA。過去の侵害の有無や実環境の状態は確認できない。",
    ],
  };
}

async function prepare({ github, context, core, workspace }) {
  const pr = await getTarget({ github, context });
  if (!pr) {
    core.info("対象外または古い実行のためスキップします。");
    return;
  }
  const data = await collect({ github, repo: context.repo, pr });
  // コードを元のパスに配置しない。PR の hooks / MCP / CLAUDE.md を読み込ませない。
  for (const version of ["before", "after"]) {
    const filename = `dependency-review-${version}.json`;
    await writeFile(
      path.join(workspace, filename),
      JSON.stringify(data[version].files, null, 2),
    );
    const { files, ...summary } = data[version];
    data[version] = { ...summary, filename, fileCount: files.length };
  }
  await writeFile(
    path.join(workspace, "dependency-review-context.json"),
    JSON.stringify(data, null, 2),
  );
  core.setOutput(
    "metadata",
    JSON.stringify({
      number: pr.number,
      head: pr.head.sha,
      base: pr.base.sha,
      repository: `${context.repo.owner}/${context.repo.repo}`,
      ci: { state: data.ci.state, checkedAt: data.ci.checkedAt },
    }),
  );
  core.setOutput("ready", "true");
}

async function publish({ github, context, metadata, report }) {
  const event = eventTarget(context);
  const repo = context.repo;
  const target = JSON.parse(metadata);
  const output = JSON.parse(report);
  if (
    !Number.isSafeInteger(target.number) ||
    !/^[a-f0-9]{40}$/.test(target.head) ||
    !/^[a-f0-9]{40}$/.test(target.base) ||
    target.repository !== `${repo.owner}/${repo.repo}` ||
    !Object.hasOwn(ciLabels, target.ci?.state) ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(
      target.ci?.checkedAt,
    ) ||
    typeof output.review !== "string" ||
    !output.review.trim() ||
    output.review.length > 48000
  ) {
    throw new Error("調査結果または対象情報が不正です。");
  }
  if (
    target.number !== event.number ||
    target.head !== event.head ||
    target.base !== event.base
  )
    return false;
  const pr = await getTarget({ github, context });
  if (!pr) return false;
  const review = output.review.replace(/@/g, "@\u200b");
  const body =
    `${marker}\n## 依存更新の調査結果\n\n${review}\n\n---\n` +
    `対象 head: \`${target.head}\`\n対象 base: \`${target.base}\`\n` +
    `CI（資料収集時点）: ${ciLabels[target.ci.state]}（${target.ci.checkedAt}）\n\n` +
    "CI 完了後の自動更新は行いません。マージ時には最新の CI 結果も確認してください。\n" +
    "Claude による調査です。実行していない検証や実環境への影響を保証するものではありません。マージは人間が判断してください。";
  const comments = await github.paginate(github.rest.issues.listComments, {
    ...repo,
    issue_number: pr.number,
    per_page: 100,
  });
  const existing = comments.find(
    (comment) =>
      comment.user?.login === "github-actions[bot]" &&
      comment.body?.startsWith(marker),
  );
  if (existing)
    await github.rest.issues.updateComment({
      ...repo,
      comment_id: existing.id,
      body,
    });
  else
    await github.rest.issues.createComment({
      ...repo,
      issue_number: pr.number,
      body,
    });
  return true;
}

module.exports = { selectTarget, collectCi, collect, prepare, publish };
