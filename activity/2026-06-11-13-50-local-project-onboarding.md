# Local project onboarding rewrite

Reworked the default model around one linked Signal secondary device per
user/host and separate project group targets in local user state.

Device onboarding now means linking and syncing the shared presage SQLite DB.
Project onboarding now means resolving a project id and storing that project's
selected group key under XDG state.

SOPS is no longer presented as the normal local workflow. It remains an
optional deployment transport when a group key must travel with declarative host
configuration.
