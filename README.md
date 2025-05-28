# linderman

Docker compose deployment of various small, internal apps for Lehigh's Library Technology team.

- Docker compose is the container orchestrator
- Traefik handles TLS, routing to apps, [LDAP authentication](#serviceapp-authentication)
- Each app is a service in the docker compose YAML, and served as a route/path under our main domain
- GitHub Actions + self hosted runner + rollout service handle code deploys. More info in [continuous deployment section](#continuous-deployment)
- This stack is deployed into SET managed VMs in Lehigh's data center


## Requirements

- [Docker 24.0+](https://docs.docker.com/get-docker/)
- [Docker Compose 2.x](https://docs.docker.com/compose/install/linux/)
- `git`

## Local development setup

First, clone your app(s)

```
git clone git@github.com:lehigh-university-libraries/folio-offline-shelf-reading
```

Next, clone this repo, which is configured to run all apps Library Technology deploys using linderman. Then run the script that generates a self-signed cert.

> [!WARNING]
> Ensure you have [mkcert 1.4+](https://github.com/FiloSottile/mkcert#installation) installed

```
git clone git@github.com:lehigh-university-libraries/linderman
cd linderman
./scripts/maintenance/generate-certs.sh
```

Start the services

```
docker compose up -d
```

You should now be able to view the apps at e.g. https://localhost/shelf-reading

You should be able to make edits to your app's code, which should be `git clone`'d into the same directory `linderman` was cloned into

```
.
├── folio-offline-shelf-reading
├── folio-shelving-order
├── linderman
```

If you need to make edits to the dockerfile on a specific app (e.g. installing a new pip dependency), you can build the docker image for your app to get the dependency installed with. e.g.

```
cd /path/to/linderman
docker compose up --build folio-shelving-order -d
```

## Continuous Deployment

This repo, as well as each app linderman hosts, references a reusable GitHub Action [linderman-deploy.yaml](https://github.com/lehigh-university-libraries/gha/blob/main/.github/workflows/linderman-deploy.yaml) to deploy changes made in GitHub into Lehigh's infrastructure. 

That shared action leverages linderman's self-hosted GitHub Action Runner, defined in [docker-compose.libapps-test.yaml](./docker-compose.libapps-test.yaml) to trigger a rollout when pushes are made to a branch. That GitHub Action runner was added to [the lehigh-university-libraries GitHub org](https://github.com/organizations/lehigh-university-libraries/settings/actions/runners) so any repo in our org can leverage the self hosted runner.

We need a self-hosted runner since the linderman services are protected via a firewall to on-campus only. The rollout workflow is basically:

- slack alert message when rollout starts
- if an app is being deployed, run `docker pull` for the app's docker tag
- else if this repo/linderman is what's being deployed, run `git pull` on the filesystem
- run `docker compose up -d` to get the changes running
- slack alert message when rollout ends (pass or fail status)

Each app can define in their GitHub Action when to deploy to test or prod. This repo deploys to test whenever a branch is pushed to this repo, and when the branch is merged into main that is deployed to test and then prod.

### Rollout Service

The logic performed during the rollout can be seen in [rollout.sh](./scripts/maintenance/rollout.sh). That script is executed by the GitHub Action using OIDC/JWT auth on [the rollout docker service](https://github.com/lehigh-university-libraries/rollout). So triggering a rollout is basically just a `cURL` call from a GitHub Action.


## Manual deployment

If ever needed, you can manually deploy linderman like so

```
ssh apps-test.lib.lehigh.edu
cd /opt/linderman
sudo git checkout main
sudo git pull origin main
sudo docker compose pull
sudo systemctl restart linderman
```

Same steps for production, except start with `ssh apps-prod.lib.lehigh.edu`

## Service/App Authentication

Any service running in linderman can leverage LDAP authentication by adding the traefik middleware `ldap-valid-user` to its traefik router in [config/traefik/config.tmpl](./config/traefik/config.tmpl). This will force LDAP authentication before the application can be loaded in the web browser, and once authenticated will forward the username via the HTTP header `X-Remote-User` to the backend service.

The LDAP traefik middleware is maintained at https://github.com/lehigh-university-libraries/ldapAuth and updates can be pulled into linderman via

```
cd path/to/linderman
git subtree pull --prefix conf/traefik/plugins/ldapAuth https://github.com/lehigh-university-libraries/ldapAuth main --squash
```

### App-specific allowed users

If an app is restricted to certain users, for privacy/security reasons, instead of hardcoding the list of users in version control, the allowed users are set in an environment variable in `.env`.

```
SHELF_READING_ALLOWED_USERS="bob
alice
terry"
```

To update the list of allowed users, you can update the environment variable, being sure to add one person per line with the entire list is wrapped in double quotes. Commenting out a user **might** work only because it requires `#` to be in the username e.g.

```bash
ssh apps-test.lib.lehigh.edu
cd /opt/linderman
sudo vim.tiny .env
docker compose up -d
```

Test, then repeat on production.

## Initial bootstrapping on SET managed stage/production VMs)

```
cd /opt
git clone git@github.com:lehigh-university-libraries/linderman
```

### rollout

A couple files need to be present on the host:

```
# docker login to auth `docker pull` inside rollout container
/root/.docker/config.json
# deploy token to run `git pull` inside rollout container
/root/.ssh/id_rsa
```

### Setup as a systemd Service

`systemd` is used to manage the docker compose stack. You can find the unit file in [scripts/systemd/linderman.service](./scripts/systemd/linderman.service)

```
cp /opt/linderman/scripts/systemd/linderman.service /etc/systemd/system/
systemctl enable linderman.service
```

