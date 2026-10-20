## Summary

<!-- Briefly describe the problem and the changes introduced by this PR. -->

## Related Issues

<!-- Link the issue(s) resolved, e.g. Closes #12 -->
Closes #

## Type of change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature or enhancement
- [ ] Documentation update
- [ ] Dependency upgrade
- [ ] Refactor / code quality improvement

## Changes made

<!-- List the files and components changed, and why. -->

-
-

## Testing

<!-- Describe how you tested this change. -->

## Verification Checklist

**Environment**
- [ ] `node scripts/check-env.js --target compose` passes (no placeholder values)

**Scripts**
- [ ] Shell scripts pass `shellcheck scripts/*.sh` and `bash -n scripts/*.sh`
- [ ] Node scripts and unit tests pass (`npm test`)
- [ ] ESLint passes (`npm run lint`)
- [ ] Prettier check passes (`npm run format:check`)

**Kubernetes** _(skip if no `k8s/` changes)_
- [ ] Manifests render cleanly (`kubectl kustomize k8s/ > /dev/null`)
- [ ] `kubeconform -strict` reports no errors
- [ ] `kube-linter lint` reports no errors

**Monitoring** _(skip if no `monitoring/` changes)_
- [ ] `promtool check rules monitoring/alert-rules.yml` passes
- [ ] `amtool check-config monitoring/alertmanager.yml` passes

**Docker Compose** _(skip if no compose/Dockerfile changes)_
- [ ] `docker compose config --quiet` passes with `.env.example`

**Documentation**
- [ ] `docs/` or `README.md` updated if operational behaviour changed
- [ ] `docs/ENVIRONMENT-VARIABLES.md` updated if any env var was added/changed
- [ ] Cross-links point to the right canonical guides (no duplicated Railway/k8s content)

**Security**
- [ ] No secrets, keys, or real credentials introduced in any file
- [ ] `k8s/secrets.yaml` not added to `k8s/kustomization.yaml`
