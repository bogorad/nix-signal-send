# Default Legacy Fallback

Roborev found that the compatibility fallback for the old
`stateDir/group_master_key` layout could apply to any named project. That was
unsafe because a project with no selected group could silently send to the old
single global group.

The fallback is now limited to the explicit `default` project. Named projects
must have their own key under `stateDir/projects/<project>/group_master_key` or
the send stops and asks for project onboarding.

This keeps the original device onboarding model simple: one linked-device DB per
user/host, with every non-default project making an explicit local group choice.
