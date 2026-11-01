# Sitetools checks · GitHub Action

Run your Sitetools checks from a workflow: send the build you just produced (or live URLs, or a sitemap), wait for the report, post it on the pull request, and fail the job when a check fails.

```yaml
- uses: dubem-design/sitetools-action@v1
  with:
    api-key: ${{ secrets.SITETOOLS_KEY }}
    site-id: ${{ vars.SITETOOLS_SITE_ID }}
    build-dir: dist
```

That is the whole integration. The step prints the verdict, writes a job summary with every failing check and its first finding, and on pull requests keeps one sticky comment up to date.

## Inputs

| Input | Required | Default | What it does |
|---|---|---|---|
| `api-key` | yes | | Space API key (Settings → Developers). Keep it in a secret. |
| `site-id` | yes | | From the dashboard URL, `/sites/<id>`. |
| `build-dir` | one of | | Directory with the generated site. Zipped and sent as the **Build** source. |
| `urls` | one of | | Live URLs or paths, one per line (**Live** source). |
| `sitemap` | one of | | A sitemap URL on the site's domain, or `auto` for `/sitemap.xml`. |
| `label` | no | commit SHA | Shown on the run in the dashboard. |
| `pack` | no | site's active pack | `all`, `ungrouped`, or a pack id. |
| `fail-on` | no | `error` | `error`, `warning`, or `none` (report only). |
| `timeout-seconds` | no | `600` | How long to wait for the run. |
| `comment` | no | `true` | Sticky pull request comment with the results. |
| `github-token` | no | `github.token` | Token for the comment. Needs `pull-requests: write`. |
| `app-url` | no | `https://app.sitetools.pro` | Self-hosted or staging instance. |

## Outputs

`run-id`, `status`, `score`, `passed`, `failed`, `warnings`, `report-url`.

## Examples

Gate a deploy on the build, comment on the PR:

```yaml
name: Site checks
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
  pull-requests: write
jobs:
  checks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run build
      - uses: dubem-design/sitetools-action@v1
        with:
          api-key: ${{ secrets.SITETOOLS_KEY }}
          site-id: ${{ vars.SITETOOLS_SITE_ID }}
          build-dir: dist
```

Check the live site after a deploy, from its sitemap, warnings included:

```yaml
- uses: dubem-design/sitetools-action@v1
  with:
    api-key: ${{ secrets.SITETOOLS_KEY }}
    site-id: ${{ vars.SITETOOLS_SITE_ID }}
    sitemap: auto
    fail-on: warning
```

Use the outputs:

```yaml
- id: sitetools
  uses: dubem-design/sitetools-action@v1
  with: { api-key: ${{ secrets.SITETOOLS_KEY }}, site-id: ${{ vars.SITETOOLS_SITE_ID }}, build-dir: dist, fail-on: none }
- run: echo "Score ${{ steps.sitetools.outputs.score }} → ${{ steps.sitetools.outputs.report-url }}"
```

## How it works

Composite action: bash, `curl`, `jq` and `zip`, all present on GitHub-hosted runners. It POSTs to `/api/v1/sites/:id/runs`, polls `/runs/:id` with a small backoff until `completed` or `failed`, writes `$GITHUB_STEP_SUMMARY`, and uses `gh api` for the comment. Runs with Rendered (real browser) or Intelligent checks take longer; raise `timeout-seconds` if needed.

## Publishing

This folder is the source of truth. `scripts/publish-action.sh` mirrors it to the public `dubem-design/sitetools-action` repository and moves the `v1` tag, so workflows can reference `@v1`.
