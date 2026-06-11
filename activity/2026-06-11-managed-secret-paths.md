# Managed secret paths

After SOPS or another runtime secret manager owns `groupKeyFile`, group
selection must not replace that managed path.

The wrapper now refuses selection when the destination is a symlink, when any
destination path component is a symlink, or when the target directory is not
writable. The README documents the intended flow: select a group into normal
local state first, then move that value into the encrypted secret source.
