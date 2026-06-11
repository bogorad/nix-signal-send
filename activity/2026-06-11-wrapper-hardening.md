# Wrapper hardening

Removed generated shell wrappers that enabled automatic failure behavior.

The package wrapper is now written directly in the derivation with
noninteractive Bash and an explicit runtime `PATH`. The NixOS module wrapper is
also a plain script wrapper instead of a generated shell application.

The Bash helper now checks group-listing failures explicitly instead of relying
on global pipeline behavior, and option parsing reports missing attachment
arguments as controlled usage errors.
