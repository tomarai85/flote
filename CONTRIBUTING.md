# Contributing to Flote

Thanks for the interest. Flote is a solo-built, source-available product, and its
contribution policy is unusual enough that it is worth reading first.

## TL;DR

- **Issues: yes.** Bug reports, feature requests and questions are all welcome.
- **Pull requests: closed for now.** External PRs are not accepted while the
  licence transition is pending.
- **PRs open on 2028-05-27**, when the licence converts to Apache 2.0 and the
  normal OSS contribution workflow starts.

## Why are PRs closed?

Flote ships under [FSL-1.1-ALv2](./LICENSE.md), the Functional Source License:

- Commercial forks -- selling the same product -- are prohibited for two years.
- On 2028-05-27 the licence converts to Apache 2.0 automatically, and community
  contribution is welcome from that point on.

Merging an external PR during that window would bind the contributor's copyright
to a licence with a two-year restriction they never agreed to, and would make the
Apache conversion messy. Closing PRs until the conversion avoids that.

## What you can do

### 1. Open an issue

- **Bug report**: steps to reproduce, environment, expected behaviour, actual behaviour.
- **Feature request**: why you want it, and what you tried instead.
- **Questions**: fine as issues or discussions.

Templates live in `.github/ISSUE_TEMPLATE/`.

### 2. Fork it and fix it for yourself

FSL permits personal and internal use, so forking and patching for your own use is
fine. Share the result in an issue and the fix can be folded into an official
patch, with attribution kept in the issue thread.

### 3. Report a security vulnerability

See [SECURITY.md](./SECURITY.md). Private Vulnerability Reporting is enabled.

## What you cannot do

- **Commercial redistribution** -- forking Flote and selling it, or hosting it as a
  paid service -- is prohibited for two years.
- **Sending pull requests**, for the licence reason above.

## After 2028-05-27

Once the licence converts to Apache 2.0:

- PRs are welcome.
- Commercial forks are permitted.
- The standard fork-PR-review workflow resumes.

Until then it runs on issues plus free forking.

## Maintainer

- [@tomarai85](https://github.com/tomarai85) -- Tomonori Arai (Tom)
- a [Direct](https://direct-homepage.vercel.app) product

Questions are welcome as issues.
