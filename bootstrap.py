"""One-shot bootstrap for the Wonton LibrePhotos plugin.

Runs via `manage.py shell` after the backend is healthy, on every container
creation (install, upgrade, rebuild). Idempotent; every value it writes comes
from injected environment variables, so a rebuilt container converges to the
same state:

* the owner account (created by the upstream entrypoint's createadmin on first
  start) gets its library pointed at the shared folder, and the changeable
  email stays in sync — SSO links the Wonton identity to this account by
  verified email, so a stale email would break every login;
* the allauth SocialApp that holds the OIDC client is updated from the
  injected variables: the core regenerates the client secret whenever the
  plugin is reinstalled (data kept), so "already exists, skip" would leave a
  dead client behind;
* the OIDC_ENABLED site switch is turned on so the login redirect is live.
"""

import os

from allauth.socialaccount.models import SocialApp
from api.models import User
from constance import config as site_config
from django.contrib.sites.models import Site

PROVIDER_ID = "wonton"

owner_name = os.environ["WONTON_OWNER_NAME"]
owner_email = os.environ["WONTON_OWNER_EMAIL"]

user = User.objects.filter(username=owner_name).first()
if user is None:
    # createadmin runs in the entrypoint before this; only reachable if the
    # account was removed some other way. No password: SSO is the only way in.
    user = User.objects.create_superuser(owner_name, owner_email)
    print(f"bootstrap: created owner account {owner_name}")
if user.email != owner_email:
    user.email = owner_email
    user.save(update_fields=["email"])
    print("bootstrap: synced owner email")
if not user.scan_directory:
    # The shared folder is mounted at /data (settings.DATA_ROOT); leave a
    # directory the owner picked in the app untouched.
    user.scan_directory = "/data"
    user.save(update_fields=["scan_directory"])
    print("bootstrap: set scan directory /data")

app = SocialApp.objects.filter(provider="openid_connect", provider_id=PROVIDER_ID).first()
if app is None:
    app = SocialApp.objects.create(
        provider="openid_connect",
        provider_id=PROVIDER_ID,
        name="Wonton",
    )
    print("bootstrap: created OIDC SocialApp")
app.client_id = os.environ["WONTON_OIDC_CLIENT_ID"]
app.secret = os.environ["WONTON_OIDC_CLIENT_SECRET"]
# token_auth_method 固定 post，和清单登记的 token_endpoint_auth_method 一致：
# allauth 不指定时按身份方 discovery 自选，可能与登记值不一致导致换 token 被拒。
app.settings = {
    "server_url": os.environ["WONTON_OIDC_ISSUER"],
    "token_auth_method": "client_secret_post",
}
app.save()
app.sites.add(Site.objects.get_or_create(pk=1)[0])
print("bootstrap: OIDC client updated")

site_config.OIDC_ENABLED = True
print("bootstrap: OIDC enabled")
