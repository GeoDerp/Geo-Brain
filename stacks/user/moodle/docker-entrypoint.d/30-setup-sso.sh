#!/usr/bin/env bash
# docker-entrypoint.d/30-setup-sso.sh
# Configures Moodle OAuth2/OIDC SSO with Kanidm.
# Run via: podman exec -e MOODLE_OIDC_SECRET=... -e DOMAIN=... -e MOODLE_WWWROOT=... moodle bash /docker-entrypoint.d/30-setup-sso.sh
# Idempotent — safe to run multiple times.
set -euo pipefail

MOODLE_ROOT="${MOODLE_ROOT:-/var/www/html}"
DOMAIN="${DOMAIN:?DOMAIN must be set}"
MOODLE_WWWROOT="${MOODLE_WWWROOT:-https://moodle.${DOMAIN}}"
MOODLE_OIDC_SECRET="${MOODLE_OIDC_SECRET:?MOODLE_OIDC_SECRET must be set}"

KANIDM_ISSUER="https://kanidm.${DOMAIN}/oauth2/openid/moodle"

cd "${MOODLE_ROOT}"

echo "[moodle-sso] Waiting for Moodle DB to be ready..."
for i in $(seq 1 30); do
  php admin/cli/cfg.php --name=version 2>/dev/null && break || sleep 5
done

echo "[moodle-sso] Ensuring site is installed..."
php admin/cli/install_database.php \
  --agree-license \
  --fullname="My-HomeLab Moodle" \
  --shortname="moodle" \
  --adminuser=admin \
  --adminpass="${MOODLE_ADMIN_PASSWORD:-changeme}" \
  --adminemail="admin@${DOMAIN}" \
  2>/dev/null || true

echo "[moodle-sso] Clearing email domain restriction (allowemailaddresses)..."
# When set to a specific domain, Moodle blocks logins from other domains.
# Kanidm issues emails like user@example.local which must be accepted.
php admin/cli/cfg.php --name=allowemailaddresses --set=''

echo "[moodle-sso] Setting site URL (may be a no-op if set in config.php)..."
php admin/cli/cfg.php --name=wwwroot --set="${MOODLE_WWWROOT}" 2>/dev/null || true

echo "[moodle-sso] Enabling OAuth2 plugin..."
php admin/cli/cfg.php --component=auth_oauth2 --name=field_map_email --set=email 2>/dev/null || true
# Enable auth_oauth2 in the active auth plugins list (idempotent)
CURRENT_AUTH=$(php admin/cli/cfg.php --name=auth 2>/dev/null | tr -d '\n' || echo "")
if echo "$CURRENT_AUTH" | grep -q "oauth2"; then
  echo "[moodle-sso] auth_oauth2 already in auth list."
else
  NEW_AUTH="${CURRENT_AUTH:+${CURRENT_AUTH},}oauth2"
  php admin/cli/cfg.php --name=auth --set="$NEW_AUTH"
  echo "[moodle-sso] auth_oauth2 added to auth list."
fi

echo "[moodle-sso] Configuring Kanidm OIDC issuer..."
# Check if a Kanidm issuer already exists
EXISTING_ID=$(php -r "
define('CLI_SCRIPT', true);
require_once('${MOODLE_ROOT}/config.php');
\$records = \$DB->get_records('oauth2_issuer', ['name' => 'kanidm']);
if (\$records) {
    echo array_values(\$records)[0]->id;
} else {
    echo '';
}
" 2>/dev/null || echo "")

if [[ -n "$EXISTING_ID" ]]; then
  echo "[moodle-sso] Kanidm issuer (ID=${EXISTING_ID}) already exists — updating secret and baseurl..."
  php -r "
define('CLI_SCRIPT', true);
require_once('${MOODLE_ROOT}/config.php');
\$DB->set_field('oauth2_issuer', 'clientsecret', '${MOODLE_OIDC_SECRET}', ['id' => ${EXISTING_ID}]);
\$DB->set_field('oauth2_issuer', 'baseurl', '${KANIDM_ISSUER}', ['id' => ${EXISTING_ID}]);
echo 'Secret and baseurl updated.';
" 2>/dev/null || true
else
  echo "[moodle-sso] Creating Kanidm OIDC issuer..."
  php -r "
define('CLI_SCRIPT', true);
require_once('${MOODLE_ROOT}/config.php');
\$now = time();
\$id = \$DB->insert_record('oauth2_issuer', (object)[
  'name'               => 'kanidm',
  'image'              => '',
  'baseurl'            => '${KANIDM_ISSUER}',
  'clientid'           => 'moodle',
  'clientsecret'       => '${MOODLE_OIDC_SECRET}',
  'loginscopes'        => 'openid profile email',
  'loginscopesoffline' => 'openid profile email',
  'loginparams'        => '',
  'loginparamsoffline' => '',
  'alloweddomains'     => '',
  'requireconfirmation'=> 0,
  'showonloginpage'    => 1,
  'enabled'            => 1,
  'sortorder'          => 0,
  'servicetype'        => 'custom',
  'timecreated'        => \$now,
  'timemodified'       => \$now,
  'usermodified'       => 2,
]);
echo \"Issuer created with ID={\$id}\n\";
" 2>/dev/null || echo "[moodle-sso] ⚠️ Could not create issuer — configure manually at ${MOODLE_WWWROOT}/admin/tool/oauth2/issuers.php"
  EXISTING_ID=$(php -r "
define('CLI_SCRIPT', true);
require_once('${MOODLE_ROOT}/config.php');
\$records = \$DB->get_records('oauth2_issuer', ['name' => 'kanidm']);
echo \$records ? array_values(\$records)[0]->id : '';
" 2>/dev/null || echo "")
fi

if [[ -n "$EXISTING_ID" ]]; then
  echo "[moodle-sso] Configuring OIDC endpoints for issuer ID=${EXISTING_ID}..."
  # Use correct Kanidm endpoint URLs from OIDC discovery.
  # authorization_endpoint is Kanidm's UI, NOT ${KANIDM_ISSUER}/authorize.
  php -r "
define('CLI_SCRIPT', true);
require_once('${MOODLE_ROOT}/config.php');
\$endpoints = [
  'authorization_endpoint' => 'https://kanidm.${DOMAIN}/ui/oauth2',
  'token_endpoint'         => 'https://kanidm.${DOMAIN}/oauth2/token',
  'userinfo_endpoint'      => '${KANIDM_ISSUER}/userinfo',
  'jwks_uri'               => '${KANIDM_ISSUER}/public_key.jwk',
  'discovery_endpoint'     => '${KANIDM_ISSUER}/.well-known/openid-configuration',
];
foreach (\$endpoints as \$name => \$url) {
  \$existing = \$DB->get_record('oauth2_endpoint', ['issuerid' => ${EXISTING_ID}, 'name' => \$name]);
  if (\$existing) {
    \$existing->url = \$url;
    \$DB->update_record('oauth2_endpoint', \$existing);
  } else {
    \$DB->insert_record('oauth2_endpoint', (object)['issuerid' => ${EXISTING_ID}, 'name' => \$name, 'url' => \$url]);
  }
}
echo 'Endpoints configured.';
" 2>/dev/null || echo "[moodle-sso] ⚠️ Could not set endpoints — check Moodle DB connection."

  echo "[moodle-sso] Configuring field mappings..."
  php -r "
define('CLI_SCRIPT', true);
require_once('${MOODLE_ROOT}/config.php');
\$mappings = [
  ['internalfield' => 'email',     'externalfield' => 'email'],
  ['internalfield' => 'firstname', 'externalfield' => 'given_name'],
  ['internalfield' => 'lastname',  'externalfield' => 'family_name'],
  ['internalfield' => 'username',  'externalfield' => 'preferred_username'],
];
foreach (\$mappings as \$m) {
  \$existing = \$DB->get_record('oauth2_user_field_mapping', ['issuerid' => ${EXISTING_ID}, 'internalfield' => \$m['internalfield']]);
  if (\$existing) {
    \$existing->externalfield = \$m['externalfield'];
    \$DB->update_record('oauth2_user_field_mapping', \$existing);
  } else {
    \$DB->insert_record('oauth2_user_field_mapping', array_merge(\$m, ['issuerid' => ${EXISTING_ID}]));
  }
}
echo 'Field mappings configured.';
" 2>/dev/null || echo "[moodle-sso] ⚠️ Could not set field mappings."
fi

echo "[moodle-sso] ✅ Moodle SSO configuration complete."
echo "[moodle-sso]    Login URL: ${MOODLE_WWWROOT}/login/index.php"
echo "[moodle-sso]    OAuth2 admin: ${MOODLE_WWWROOT}/admin/tool/oauth2/issuers.php"
