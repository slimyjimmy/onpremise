#!/usr/bin/env bash

#Fix starting screen setup issue https://github.com/getsentry/sentry/issues/12722
echo "Set config.yml"

cat <<EOT > config.yml
auth.allow-registration: false
beacon.anonymous: true
mail.backend: 'smtp'
mail.from: "foo@example.com"
mail.host: "smtp.example.com"
mail.password: "somesecurepassword"
mail.port: 465
mail.use-tls: true
mail.username: "foo@example.com"
system.admin-email: "admin@example.com"
system.url-prefix: "https://devnull.example.com/"
EOT
echo "Build Sentry onpremise"
make build

docker container stop sentry-cron sentry-worker sentry-web sentry-postgres sentry-redis
docker container rm sentry-cron sentry-worker sentry-web sentry-postgres sentry-redis

docker run \
  --detach \
  --name sentry-redis \
  redis:3.2-alpine

docker run \
  --detach \
  --name sentry-postgres \
  --env POSTGRES_PASSWORD='sentry' \
  --env POSTGRES_USER=sentry \
  -v /opt/docker/sentry/postgres:/var/lib/postgresql/data \
  postgres:11

echo "Generate secret key"
docker run --rm sentry-onpremise config generate-secret-key > key
SENTRY_SECRET_KEY=$(cat key)

echo "Run migrations"
docker run \
  --rm \
  -it \
  --link sentry-redis:redis \
  --link sentry-postgres:postgres \
  --env SENTRY_SECRET_KEY=${SENTRY_SECRET_KEY} \
  -v /opt/docker/sentry/sentry:/var/lib/sentry/files \
  sentry-onpremise \
  upgrade

echo "install plugins"
docker run \
  --rm \
  -it \
  --link sentry-redis:redis \
  --link sentry-postgres:postgres \
  --env SENTRY_SECRET_KEY=${SENTRY_SECRET_KEY} \
  -v /opt/docker/sentry/sentry:/var/lib/sentry/files \
  sentry-onpremise \
  pip install sentry-plugins

echo "Run service WEB"
docker run \
  --detach \
  --link sentry-redis:redis \
  --link sentry-postgres:postgres \
  --env SENTRY_SECRET_KEY=${SENTRY_SECRET_KEY} \
  --name sentry-web \
  --publish 9000:9000 \
  -v /opt/docker/sentry/sentry:/var/lib/sentry/files \
  sentry-onpremise \
  run web
sleep 15
echo "Run service WORKER"
docker run \
  --detach \
  --link sentry-redis:redis \
  --link sentry-postgres:postgres \
  --env SENTRY_SECRET_KEY=${SENTRY_SECRET_KEY} \
  --name sentry-worker \
  -v /opt/docker/sentry/sentry:/var/lib/sentry/files \
  sentry-onpremise \
  run worker
sleep 15
echo "Run service CRON"
docker run \
  --detach \
  --link sentry-redis:redis \
  --link sentry-postgres:postgres \
  --env SENTRY_SECRET_KEY=${SENTRY_SECRET_KEY} \
  --name sentry-cron \
  -v /opt/docker/sentry/sentry:/var/lib/sentry/files \
  sentry-onpremise \
  run cron

echo "Set config https://github.com/getsentry/sentry/issues/12722"
date
sleep 60
date
docker exec sentry-web sentry config set sentry:version-configured '9.1.0'
