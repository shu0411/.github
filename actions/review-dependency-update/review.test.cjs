const { test } = require("node:test");
const assert = require("node:assert/strict");
const {
  selectTarget,
  collectCi,
  publish,
  collect,
  prepare,
} = require("./review.cjs");
const sha = "a".repeat(40);
const base = "b".repeat(40);
const repo = { owner: "shu0411", repo: "trade-lab" };
const pr = () => ({
  number: 12,
  state: "open",
  user: { login: "dependabot[bot]" },
  head: {
    sha,
    ref: "dependabot/npm_and_yarn/frontend/example",
    repo: { full_name: "shu0411/trade-lab" },
  },
  base: { sha: base, repo: { full_name: "shu0411/trade-lab" } },
});
const expected = () => ({ number: 12, head: sha, base });
const context = () => ({
  eventName: "pull_request_target",
  repo,
  payload: { action: "opened", pull_request: pr() },
});
const run = () => ({
  id: 91,
  workflow_id: 3,
  name: "PR Checks",
  event: "pull_request",
  status: "completed",
  conclusion: "failure",
  path: ".github/workflows/pr-checks.yml",
  head_sha: sha,
  html_url: "https://github.com/shu0411/trade-lab/actions/runs/91",
  repository: { full_name: "shu0411/trade-lab" },
  pull_requests: [{ number: 12, head: { sha }, base: { sha: base } }],
});
const options = () => ({ repo: { ...repo }, pr: pr(), expected: expected() });

test("ユーザー ID と先行 CI がなくても Dependabot PR を対象にする", () => {
  assert.equal(selectTarget(options()).number, 12);
});
for (const [name, mutate] of [
  [
    "通常のブランチ名",
    (o) => {
      o.pr.head.ref = "feature/update";
    },
  ],
  [
    "接頭辞が似ているブランチ名",
    (o) => {
      o.pr.head.ref = "dependabot-fake/update";
    },
  ],
  [
    "通常ユーザーの PR",
    (o) => {
      o.pr.user.login = "someone";
    },
  ],
  [
    "fork の PR",
    (o) => {
      o.pr.head.repo.full_name = "other/trade-lab";
    },
  ],
  [
    "更新済みの head",
    (o) => {
      o.pr.head.sha = "c".repeat(40);
    },
  ],
  [
    "更新済みの base",
    (o) => {
      o.pr.base.sha = "c".repeat(40);
    },
  ],
  [
    "別の PR 番号",
    (o) => {
      o.pr.number = 13;
    },
  ],
  [
    "閉じた PR",
    (o) => {
      o.pr.state = "closed";
    },
  ],
  [
    "別のリポジトリ",
    (o) => {
      o.repo.repo = "other";
    },
  ],
]) {
  test(`${name}は対象外にする`, () => {
    const o = options();
    mutate(o);
    assert.equal(selectTarget(o), null);
  });
}

function mockGithub(comments = [], runs = [run()]) {
  const calls = [];
  const github = {
    paginate: async (method, args) => method(args),
    rest: {
      actions: {
        listWorkflowRunsForRepo: async (args) => {
          calls.push(["listRuns", args]);
          return runs;
        },
        downloadJobLogsForWorkflowRun: async () => ({
          data: "Error: [postcss] PostCSS の設定が不正です。",
        }),
        listJobsForWorkflowRun: async () => [
          { id: 8, name: "ビルド", conclusion: "failure", steps: [] },
        ],
      },
      pulls: {
        get: async () => ({ data: pr() }),
        listFiles: async (args) => {
          calls.push(["listFiles", args]);
          return [];
        },
        listCommits: async () => [{ sha, commit: { message: message() } }],
      },
      git: {
        getTree: async () => ({
          data: {
            tree: [
              {
                path: ".claude/settings.json",
                mode: "100644",
                type: "blob",
                sha: "1",
                size: 10,
              },
              {
                path: "src/app.ts",
                mode: "120000",
                type: "blob",
                sha: "2",
                size: 10,
              },
              {
                path: "src/main.ts",
                mode: "100644",
                type: "blob",
                sha: "3",
                size: 10,
              },
            ],
          },
        }),
        getBlob: async () => ({
          data: {
            content: Buffer.from("export const value = 1;").toString("base64"),
            encoding: "base64",
          },
        }),
      },
      issues: {
        listComments: async () => comments,
        createComment: async (args) => {
          calls.push(["create", args]);
        },
        updateComment: async (args) => {
          calls.push(["update", args]);
        },
      },
    },
  };
  return { github, calls };
}
const updates = (version = "4.17.21") =>
  "updated-dependencies:\n- dependency-name: lodash\n" +
  `  dependency-version: ${version}\n  dependency-type: direct:production\n...`;
const message = (version) =>
  `Bump lodash from 4.17.20 to ${version}\n\n---\n${updates(version)}\n\n` +
  "Signed-off-by: dependabot[bot] <support@github.com>";
const updatesKey = require("node:crypto")
  .createHash("sha256")
  .update(updates())
  .digest("hex");
const checkedAt = "2026-10-22T00:00:00.000Z";
const metadata = () =>
  JSON.stringify({
    ...expected(),
    repository: "shu0411/trade-lab",
    ci: { state: "in_progress", checkedAt },
    updates: updatesKey,
  });
const report = () =>
  JSON.stringify({ review: "調査結果です。追加修正が必要です。" });
const pubOptions = (github) => ({
  github,
  context: context(),
  metadata: metadata(),
  report: report(),
});
const commentsOnly = (calls) =>
  calls.filter(([name]) => ["create", "update"].includes(name));

for (const [name, status, conclusion, state] of [
  ["CI が実行中", "in_progress", null, "in_progress"],
  ["CI が待機中", "queued", null, "in_progress"],
  ["CI が成功", "completed", "success", "success"],
  ["CI が失敗", "completed", "failure", "failure"],
  ["CI が中断", "completed", "cancelled", "incomplete"],
]) {
  test(`${name}でも完了を待たずに資料を作る`, async () => {
    const { github } = mockGithub([], [{ ...run(), status, conclusion }]);
    const data = await collect({ github, repo, pr: pr() });
    assert.equal(data.ci.state, state);
    assert.equal(data.ci.runs[0].status, status);
  });
}
test("CI の実行が見つからなくても未設定または未開始と記録して継続する", async () => {
  const { github } = mockGithub([], []);
  assert.equal(
    (await collect({ github, repo, pr: pr() })).ci.state,
    "undetected",
  );
});
test("CI の取得権限がなくても未確認と記録して継続する", async () => {
  const { github } = mockGithub();
  github.rest.actions.listWorkflowRunsForRepo = async () => {
    throw new Error("403");
  };
  assert.equal(
    (await collect({ github, repo, pr: pr() })).ci.state,
    "unavailable",
  );
});
test("古いコミット・古い base・別 PR・調査自身の CI 結果は混ぜない", async () => {
  const { github } = mockGithub(
    [],
    [
      { ...run(), head_sha: "c".repeat(40) },
      {
        ...run(),
        pull_requests: [
          { number: 12, head: { sha }, base: { sha: "c".repeat(40) } },
        ],
      },
      {
        ...run(),
        pull_requests: [{ number: 13, head: { sha }, base: { sha: base } }],
      },
      { ...run(), event: "pull_request_target" },
    ],
  );
  assert.equal(
    (await collectCi({ github, repo, pr: pr() })).state,
    "undetected",
  );
});
test("同じワークフローの再実行は最新の結果を使う", async () => {
  const { github } = mockGithub(
    [],
    [run(), { ...run(), id: 92, conclusion: "success" }],
  );
  const data = await collectCi({ github, repo, pr: pr() });
  assert.equal(data.state, "success");
  assert.equal(data.runs.length, 1);
});
test("複数の CI のうち一つでも実行中なら検証完了としない", async () => {
  const { github } = mockGithub(
    [],
    [
      { ...run(), conclusion: "success" },
      { ...run(), id: 92, workflow_id: 4, status: "queued", conclusion: null },
    ],
  );
  assert.equal(
    (await collectCi({ github, repo, pr: pr() })).state,
    "in_progress",
  );
});
test("コードは JSON 内のデータとして収集し、設定やシンボリックリンクを展開しない", async () => {
  const { github } = mockGithub();
  const result = await collect({ github, repo, pr: pr() });
  assert.deepEqual(
    result.before.files.map((f) => f.path),
    ["src/main.ts"],
  );
  assert.match(result.before.files[0].lines.join("\n"), /export const/);
  assert.ok(result.before.omitted.includes(".claude/settings.json"));
  assert.match(result.ci.runs[0].failureLogs[0].tail, /postcss/);
});
test("投稿前に対象を再確認し、資料収集時点の CI 状態を明記する", async () => {
  const { github, calls } = mockGithub();
  await publish(pubOptions(github));
  const [kind, args] = commentsOnly(calls)[0];
  assert.equal(kind, "create");
  assert.match(args.body, /aaaaaaaa/);
  assert.match(args.body, /実行中/);
  assert.ok(args.body.includes(checkedAt));
  assert.equal(calls.filter(([name]) => name === "listRuns").length, 0);
});
test("自分が投稿した既存コメントを更新する", async () => {
  const { github, calls } = mockGithub([
    { id: 1, user: { login: "someone" }, body: "<!-- dependency-review -->" },
    {
      id: 2,
      user: { login: "github-actions[bot]" },
      body: "<!-- dependency-review -->",
    },
  ]);
  await publish(pubOptions(github));
  assert.equal(commentsOnly(calls)[0][0], "update");
  assert.equal(commentsOnly(calls)[0][1].comment_id, 2);
});
test("調査中に PR が更新されたら投稿しない", async () => {
  const { github, calls } = mockGithub();
  github.rest.pulls.get = async () => ({
    data: { ...pr(), head: { ...pr().head, sha: "d".repeat(40) } },
  });
  assert.equal(await publish(pubOptions(github)), false);
  assert.equal(commentsOnly(calls).length, 0);
});
test("別 PR の調査結果は投稿しない", async () => {
  const { github, calls } = mockGithub();
  const event = context();
  event.payload.pull_request.number = 13;
  assert.equal(await publish({ ...pubOptions(github), context: event }), false);
  assert.equal(commentsOnly(calls).length, 0);
});
for (const invalid of ["{}", JSON.stringify({ review: "あ".repeat(48001) })]) {
  test("不正なモデル出力ではコメントしない", async () => {
    const { github, calls } = mockGithub();
    await assert.rejects(publish({ ...pubOptions(github), report: invalid }));
    assert.equal(commentsOnly(calls).length, 0);
  });
}
test("モデル出力のメンションを無効化する", async () => {
  const { github, calls } = mockGithub();
  await publish({
    ...pubOptions(github),
    report: JSON.stringify({ review: "@claude @someone を確認" }),
  });
  assert.ok(!commentsOnly(calls)[0][1].body.includes("@claude"));
});
test("収集したコードを元のパスに置かず、分割して読める資料として保存する", async () => {
  const { mkdtemp, readFile, readdir } = require("node:fs/promises");
  const workspace = await mkdtemp("/tmp/dependency-review-test-");
  const { github } = mockGithub([], []);
  const outputs = {};
  await prepare({
    github,
    context: context(),
    core: {
      setOutput: (key, value) => {
        outputs[key] = value;
      },
      info: () => {},
    },
    workspace,
  });
  assert.equal(outputs.ready, "true");
  const target = JSON.parse(outputs.metadata);
  assert.equal(target.head, sha);
  assert.equal(target.ci.state, "undetected");
  const data = JSON.parse(
    await readFile(`${workspace}/dependency-review-context.json`, "utf8"),
  );
  const code = JSON.parse(
    await readFile(`${workspace}/${data.before.filename}`, "utf8"),
  );
  assert.equal(code[0].lines[0], "export const value = 1;");
  assert.deepEqual((await readdir(workspace)).sort(), [
    "dependency-review-after.json",
    "dependency-review-before.json",
    "dependency-review-context.json",
  ]);
});
test("旧方式の CI 完了イベントは受け付けない", async () => {
  const { github } = mockGithub();
  await assert.rejects(
    publish({
      ...pubOptions(github),
      context: { ...context(), eventName: "workflow_run" },
    }),
  );
});
test("失敗ログを取得できなくても未確認と記録して調査を継続する", async () => {
  const { github } = mockGithub();
  github.rest.actions.downloadJobLogsForWorkflowRun = async () => {
    throw new Error("取得できません");
  };
  const data = await collect({ github, repo, pr: pr() });
  assert.equal(data.ci.runs[0].failureLogs[0].unavailable, true);
});
const prepareOptions = (github) => {
  const outputs = {};
  const core = {
    setOutput: (key, value) => {
      outputs[key] = value;
    },
    info: () => {},
  };
  return { outputs, options: { github, context: context(), core } };
};
const reviewed = (key = updatesKey) => [
  {
    id: 2,
    user: { login: "github-actions[bot]" },
    body: `<!-- dependency-review -->\n<!-- dependency-review-updates: ${key} -->\n調査結果`,
  },
];
test("rebase などで依存の更新内容が調査済みなら資料収集前に中断する", async () => {
  const { github, calls } = mockGithub(reviewed());
  const { outputs, options } = prepareOptions(github);
  await prepare({ ...options, workspace: "/nonexistent" });
  assert.equal(outputs.ready, undefined);
  assert.equal(calls.filter(([name]) => name === "listFiles").length, 0);
});
for (const [name, mutate] of [
  [
    "依存の版が変わった",
    (github) => {
      github.rest.pulls.listCommits = async () => [
        { sha, commit: { message: message("4.17.22") } },
      ];
    },
  ],
  [
    "コミットが追加された",
    (github) => {
      github.rest.pulls.listCommits = async () => [
        { sha: base, commit: { message: message() } },
        { sha, commit: { message: "修正" } },
      ];
    },
  ],
  [
    "更新内容がコミットメッセージにない",
    (github) => {
      github.rest.pulls.listCommits = async () => [
        { sha, commit: { message: "Bump lodash" } },
      ];
    },
  ],
]) {
  test(`${name}場合は既存コメントがあっても再調査する`, async () => {
    const { mkdtemp } = require("node:fs/promises");
    const { github } = mockGithub(reviewed(), []);
    mutate(github);
    const { outputs, options } = prepareOptions(github);
    await prepare({
      ...options,
      workspace: await mkdtemp("/tmp/dependency-review-test-"),
    });
    assert.equal(outputs.ready, "true");
  });
}
test("他人のコメントに同じ記録があっても調査を中断しない", async () => {
  const { mkdtemp } = require("node:fs/promises");
  const comments = reviewed();
  comments[0].user.login = "someone";
  const { github } = mockGithub(comments, []);
  const { outputs, options } = prepareOptions(github);
  await prepare({
    ...options,
    workspace: await mkdtemp("/tmp/dependency-review-test-"),
  });
  assert.equal(outputs.ready, "true");
  assert.equal(JSON.parse(outputs.metadata).updates, updatesKey);
});
test("調査した依存の更新内容をコメントに記録する", async () => {
  const { github, calls } = mockGithub();
  await publish(pubOptions(github));
  assert.ok(
    commentsOnly(calls)[0][1].body.includes(
      `<!-- dependency-review-updates: ${updatesKey} -->`,
    ),
  );
});
