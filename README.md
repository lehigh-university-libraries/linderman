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
./scripts/maintenance/create-secrets.sh
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

## Adding a New Service

To add a new service to linderman, follow these steps:

1. **Define Traefik router and service** in [conf/traefik/config.tmpl](./conf/traefik/config.tmpl)
   - Add a router that matches the path prefix for your service
   - Add a corresponding service pointing to your docker container
```yaml
http:
  routers:
    my-app:
      rule: "PathPrefix(`/my-app`)"
      service: my-app
  services:
    my-app:
      loadBalancer:
        servers:
          - url: "http://my-app:8000"
```

2. **Create secrets directory** (if needed)
   - If your service requires secrets (API keys, credentials, etc.), create a directory in `secrets/` named after your docker compose service name
   - Add the necessary secret files to this directory
   - these secrets will get created automatically for you on the host VMs but you'll need to populate them with their contents

```bash
mkdir -p secrets/my-app
echo "secret-value" > secrets/my-app/api-key
```

3. **Add service definition to docker-compose.yaml**
   - Define your service with the appropriate image, volumes, environment variables, etc.
   - Ensure the service name matches what you referenced in the Traefik configuration

```yaml
services:
  my-app:
    image: my-org/my-app:latest
    environment:
      SCRIPT_NAME: /my-app
    volumes:
      - ./secrets/my-app/api-key:/app/api-key:ro
```


4. **Configure app for path prefix compatibility**
   - Your application must be compatible with running under a Traefik path prefix (e.g. `/shelf-reading`)
   - For Python/Flask/Gunicorn apps, set the `SCRIPT_NAME` environment variable on the container to match your path prefix
    - Example: `SCRIPT_NAME=/my-app` in your docker-compose service definition (shown above in step 2)

5. **Ensure rollout.sh knows how to rollout your app**
  - [./scripts/maintenance/rollout.sh](./scripts/maintenance/rollout.sh) needs to know which docker compose service needs restarted when you app deploys to linderman. This is done by specifying the docker tag environment variable, docker compose service name, and git repo that will trigger the deploy. You can use the other `if/elif` statements as an example how to add this

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

To update the list of allowed users, you can update the environment variable, being sure to add one person per line with the entire list wrapped in double quotes (`"`). Commenting out a user in the list **might** work only because it requires `#` to be in the username e.g.

```bash
ssh apps-test.lib.lehigh.edu
cd /opt/linderman
sudo vim.tiny .env
docker compose up -d
```

`docker compose up -d` should have rebuilt the traefik container with your new environment variable value of allowed users.

On test, we have debug logging enabled on traefik, so you should see the new person(s) in the list of allowed users

```
docker compose logs traefik --tail 50
```

If all is well, you can repeat the steps on production (though there is no debug logging on production, so you won't see the users in the logs).

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

## Docker compose liveness probes

Linderman test and prod both use [docker-autoheal](https://github.com/lehigh-university-libraries/docker-autoheal) to ensure the services recover after docker daemon restarts (i.e. OS upgrades) and are healthy. The process is ran using [systemd](./scripts/systemd/docker-autoheal.service) and was installed like so:

```bash
$ curl -Lo dah.tar.gz "https://github.com/lehigh-university-libraries/docker-autoheal/releases/download/0.2.8/docker-autoheal_Linux_x86_64.tar.gz"
$ tar -zxvf dah.tar.gz
$ sudo mv docker-autoheal /usr/bin/
$ sudo systemctl enable docker-autoheal.service
$ sudo systemctl start docker-autoheal.service
```

## TLS Certs

Traefik uses Lehigh's Let's Encrypt wildcard certificate from the `certs`
directory bind-mounted into the container. The weekly wildcard updater invokes
`/usr/local/sbin/local-cert-hook` after it downloads these files:

- Full certificate chain: `/etc/ssl/certs/le/lib.lehigh.edu.pem`
- Private key: `/etc/ssl/private/le/lib.lehigh.edu.key`

Install the hook and its root-only configuration on each Docker host:

```
cd /opt/linderman
sudo install -o root -g root -m 0600 \
  scripts/maintenance/local-cert-hook.env.example \
  /etc/default/local-cert-hook
sudoedit /etc/default/local-cert-hook # set SLACK_WEBHOOK and EXPECTED_HOST
sudo install -o root -g root -m 0755 \
  scripts/maintenance/lehigh-certs.sh \
  /usr/local/sbin/local-cert-hook
sudo chown root:root \
  /opt/linderman \
  /opt/linderman/.env \
  /opt/linderman/docker-compose.yaml \
  /opt/linderman/docker-compose.libapps-test.yaml \
  /opt/linderman/docker-compose.libapps-prod.yaml \
  /opt/linderman/certs
sudo chmod go-w \
  /opt/linderman \
  /opt/linderman/docker-compose.yaml \
  /opt/linderman/docker-compose.libapps-test.yaml \
  /opt/linderman/docker-compose.libapps-prod.yaml \
  /opt/linderman/certs
sudo chmod 0600 /opt/linderman/.env
```

The hook validates the full chain, hostname, expiry, private key, and key/cert
pair before changing anything. It compares SHA-256 checksums with the files
already mounted into Traefik, so an unchanged renewal exits without recreating
the container. When either file has changed, it stages and installs both files,
then force-recreates only Traefik and waits for its healthcheck. Any validation,
Compose, or healthcheck failure is sent to Slack and logged to stderr and
syslog.

The hook automatically selects `docker-compose.$(hostname --short).yaml` in
addition to the base Compose file. Set `COMPOSE_HOST` or `COMPOSE_OVERRIDE` in
`/etc/default/local-cert-hook` if a host's Compose filename does not match its
short hostname.

The hook and every path used for root-level Compose operations must remain
root-owned and not group/world-writable. Salt can manage the two installed
files instead of the commands above; keep `/etc/default/local-cert-hook` at
mode `0600` because it contains the Slack webhook.

To invoke the same hook manually:

```
sudo /usr/local/sbin/local-cert-hook
```
