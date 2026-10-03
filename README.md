# postiz

[Postiz](https://postiz.com), the social media scheduler the events team uses to draft, schedule and publish posts to Discord, YouTube, Facebook and Instagram. It runs in Docker on the Vanderbilt VPS at <https://social.flyindycenter.com>. Staff use its web app; nothing else calls it.

[![Build and Deploy](https://github.com/Indy-Center/postiz/actions/workflows/build-and-deploy.yml/badge.svg)](https://github.com/Indy-Center/postiz/actions/workflows/build-and-deploy.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

This is a trial deployment. This repository holds no Postiz code: the VPS runs Postiz's published image, `ghcr.io/gitroomhq/postiz-app`, pinned in `deploy/docker-compose.yml`. People sign in with Postiz's own email and password accounts, not with identity (see [Signing in with identity](#signing-in-with-identity)).

## HTTP surface

Postiz serves everything on one hostname:

- `GET /` — the web app: calendar, post editor, channels, team settings.
- `/api/*` — the backend the web app calls. `GET /api/monitor/queue/<name>` answers once the backend is up; the deploy checks it.
- `GET /uploads/*` — media attached to posts. Public, so the social networks can fetch it when a post publishes.
- `GET /integrations/social/<provider>` — where each social network's OAuth flow returns when a channel is connected.

## Project layout

- `deploy/`: everything deployed to `/home/deploy/apps/postiz/` on the VPS, and nothing else.
  - `docker-compose.yml`: Postiz, its Postgres database, Redis, Temporal, their volumes and the Traefik labels.
  - `dynamicconfig/development-sql.yaml`: Temporal's dynamic config, copied from Postiz's repository.
  - `.env.example`: the runtime settings the deploy writes to `.env`.
- `.github/workflows/ci.yml`: validates the compose file, pulls every image, then starts the whole stack on the runner and waits for Postiz to answer.
- `.github/workflows/build-and-deploy.yml`: runs CI, rsyncs `deploy/` to the VPS and runs `docker compose up -d` over SSH. There's no build step; the job keeps the name the other VPS apps use.

## How it differs from Postiz's compose file

Postiz's own `docker-compose.yaml` is written for trying it on a laptop. This one keeps its services and versions but:

- drops Elasticsearch, the Temporal UI, Temporal admin tools and Sentry Spotlight. Temporal stores its visibility data in Postgres instead of Elasticsearch, which it supports and which saves the most memory;
- runs one Postgres server for Postiz and Temporal, instead of one each. Temporal creates its own `temporal` and `temporal_visibility` databases in it;
- publishes no ports; Traefik reaches Postiz on port 5000 over `traefik-shared`;
- sets `SKIP_ADD_CUSTOM_SEARCH_ATTRIBUTES`. Postgres visibility allows only three custom Text search attributes, and Temporal's sample ones would take all three. Postiz's backend then can't register `organizationId` and `postId`: it stays up but never listens, so only a request to it notices;
- makes Postiz wait for Temporal's `default` namespace, which it needs at startup;
- caps Postiz at 3 GB of memory. It idles at about 1.9 GB, and the whole stack at about 2.2 GB. The first deploy refuses to start it unless the VPS has 2.6 GB available.

## Data

Everything lives in Docker volumes on the VPS, named after the repository: `postiz_db-data` (Postiz's and Temporal's databases), `postiz_uploads` (post media), `postiz_redis-data` and `postiz_config`. Backups are handled by a separate service, not by this repository. Renaming the repository starts the app on new, empty volumes.

## Accounts

`DISABLE_REGISTRATION` is `true` unless the `ENV_DISABLE_REGISTRATION` variable says otherwise. With it on, Postiz allows exactly one password sign-up, the first, and that person owns the workspace. It also blocks invited teammates from signing up, so adding people takes three steps:

1. Set the repository variable `ENV_DISABLE_REGISTRATION` to `false` and re-run the deploy.
2. Invite them from **Settings → Teams** and have them accept.
3. Delete the variable (or set it to `true`) and re-run the deploy.

While it's `false`, anyone who finds the address can create their own workspace and connect channels through our developer apps.

## Signing in with identity

Postiz can sign people in through any OAuth provider (`POSTIZ_GENERIC_OAUTH`). Identity can't be that provider yet: its `/oauth/*` HTTP endpoints aren't deployed (DEV-136). When they are, Postiz at v2.25.0 needs:

- an authorize endpoint taking `client_id`, `response_type=code`, `scope=openid profile email`, `state` and `redirect_uri=https://social.flyindycenter.com/settings`. Postiz doesn't use PKCE.
- a token endpoint taking a form-encoded `authorization_code` grant with `client_id` and `client_secret` in the body.
- a userinfo endpoint taking the bearer token and returning at least `sub` (Postiz's user id) and `email`.

Identity also has to decide who may sign in. Postiz lets anyone who completes the OAuth flow create an account and workspace, even with `DISABLE_REGISTRATION` on, so identity should only complete the flow for people with an events or staff role.

## Connecting channels

Each social network needs a developer app of our own, whose credentials go in the repository's `ENV_*` secrets (`deploy/.env.example` lists them). A channel stays greyed out in Postiz until its credentials are set. Every app's redirect URI is `https://social.flyindycenter.com/integrations/social/<provider>`, for example `.../integrations/social/discord`. [Postiz's provider docs](https://docs.postiz.com/providers) walk through creating each one.

- **Discord**: an application with a bot. The quickest to set up.
- **YouTube**: a Google Cloud project with the YouTube Data API enabled and an OAuth client.
- **Facebook and Instagram**: one Meta app covers both. Instagram must be a professional account linked to a Facebook Page.

## Local development

Needs Docker.

```bash
docker network create traefik-shared   # once; stands in for the VPS's Traefik network
cd deploy
JWT_SECRET=local POSTGRES_PASSWORD=postiz docker compose up -d
```

Traefik isn't running locally, so reach Postiz with `docker compose exec app node -e "fetch('http://127.0.0.1:5000/api/monitor/queue/local').then(r => console.log(r.status))"`, or temporarily add `ports: ['5000:5000']` to `app` and set its three URLs to `http://localhost:5000`.

## Deployment

`build-and-deploy.yml` runs on every push to `main`, and by hand from **Actions → Build and Deploy → Run workflow**. It calls `ci.yml` first and only deploys if it passes. If Postiz isn't already running it checks the VPS has 2.6 GB of memory available. After `docker compose up -d` it checks the containers are still up 15 seconds later, then requests `/api/monitor/queue/deploy` through Traefik. [Deploying to the VPS](https://tech.flyindycenter.com/patterns/vps-apps/) describes the pipeline.

Before the first deploy:

1. An org admin adds this repository to the organization's `VANDERBILT_*` variables and secrets (all four).
2. Set the repository's `ENV_*` secrets and variables; `deploy/.env.example` describes each one. Keep the source copies in 1Password.
3. Open <https://social.flyindycenter.com> straight away and create the first account. Until someone does, anyone who finds the address can.

`ENV_POSTGRES_PASSWORD` is only read when the database volume is first created. Changing the secret afterwards doesn't change the database's password, and neither Postiz nor Temporal can connect.

To upgrade Postiz, read its [release notes](https://github.com/gitroomhq/postiz-app/releases) for infrastructure changes, compare its `docker-compose.yaml` at the new tag with this one, then change the image tag in a pull request.

## Disclaimer

We are not affiliated with the FAA or any aviation governing body. This software is for flight simulation use on the [VATSIM](https://www.vatsim.net) network.
