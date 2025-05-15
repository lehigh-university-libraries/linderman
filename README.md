# linderman

## Requirements

- [Docker 24.0+](https://docs.docker.com/get-docker/)
- [Docker Compose 2.x](https://docs.docker.com/compose/install/linux/) **Already included in OSX with Docker**
- [mkcert 1.4+](https://github.com/FiloSottile/mkcert) **Local Development only**
- `cURL` and `git`

## Initial setup

First, clone your app(s)

```
git clone git@github.com:lehigh-university-libraries/folio-offline-shelf-reading
```

Next, clone this repo, which is configured to run all apps Library Technology deploys using linderman.

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
├── linderman
├── sentence-transformer-service
```

If you need to make edits to the dockerfile on a specific app (e.g. installing a new pip dependency), you can build the docker image for your app to get the dependency installed with. e.g.

```
cd /path/to/linderman
docker compose up --build shelf-reading -d
```

## Manual deployment

```
ssh apps-test.lib.lehigh.edu
cd /opt/linderman
sudo git pull origin main
sudo docker compose pull
sudo systemctl restart linderman
```

Same steps for production, except start with `ssh apps-prod.lib.lehigh.edu`

## Authentication

Any service running in linderman can leverage LDAP authentication by adding the traefik middleware `ldap-valid-user` to its router. This will force LDAP authentication before access the application, and will forward the username via the HTTP header `X-Remote-User`.

The LDAP traefik middleware is maintined at https://github.com/lehigh-university-libraries/ldapAuth and updates can be pulled into linderman via

```
cd path/to/linderman
git subtree pull --prefix conf/traefik/plugins/ldapAuth https://github.com/lehigh-university-libraries/ldapAuth main --squash
```

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

