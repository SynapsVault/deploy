#!/usr/bin/env bash
# Verify that every image in the rendered kustomization carries a readable SBOM
# and a provenance attestation tied to its digest, before kubectl apply (#157).
#
# Requires COSIGN_IDENTITY (the signing workflow identity) and
# COSIGN_OIDC_ISSUER (the OIDC issuer) environment variables, the same ones the
# signature gate uses. The attestation predicate types default to SPDX JSON for
# the SBOM and SLSA provenance; override them with SBOM_PREDICATE_TYPE and
# PROVENANCE_PREDICATE_TYPE (any value `cosign verify-attestation --type`
# accepts, e.g. `cyclonedx` or `slsaprovenance1`).
set -euo pipefail

KUSTOMIZE_DIR="${1:?usage: verify-image-attestations.sh <kustomize-dir>}"
SBOM_TYPE="${SBOM_PREDICATE_TYPE:-spdxjson}"
PROVENANCE_TYPE="${PROVENANCE_PREDICATE_TYPE:-slsaprovenance}"

if [ -z "${COSIGN_IDENTITY:-}" ] || [ -z "${COSIGN_OIDC_ISSUER:-}" ]; then
  echo "::error::Set COSIGN_IDENTITY and COSIGN_OIDC_ISSUER on the deploy environment before deploying"
  exit 1
fi

RENDERED="$(kubectl kustomize "$KUSTOMIZE_DIR")"
IMAGES="$(printf '%s\n' "$RENDERED" | yq -N '[.. | select(has("image")) | .image] | unique | .[]')"

if [ -z "$IMAGES" ]; then
  echo "::error::No container images found in ${KUSTOMIZE_DIR}"
  exit 1
fi

failures=0

# check_attestation <image> <digest-hex> <label> <cosign-type>
check_attestation() {
  local image="$1" digest="$2" label="$3" type="$4" envelopes err statements subjects
  err="$(mktemp)"
  if ! envelopes="$(cosign verify-attestation \
      --type "$type" \
      --certificate-identity "$COSIGN_IDENTITY" \
      --certificate-oidc-issuer "$COSIGN_OIDC_ISSUER" \
      "$image" 2>"$err")"; then
    echo "::error::Missing or unverifiable ${label} attestation (type '${type}') for ${image}: $(tail -n 1 "$err")"
    rm -f "$err"
    return 1
  fi
  rm -f "$err"

  # Each output line is a DSSE envelope; its payload is the in-toto statement.
  if ! statements="$(printf '%s\n' "$envelopes" \
      | jq -c 'select(type == "object" and has("payload")) | .payload | @base64d | fromjson')" \
      || [ -z "$statements" ]; then
    echo "::error::${label} attestation for ${image} is not a readable in-toto statement"
    return 1
  fi

  if ! printf '%s\n' "$statements" | jq -e -s --arg d "$digest" \
      'any(.[]; any(.subject[]?; .digest.sha256 == $d) and (.predicate | type == "object" and length > 0))' \
      >/dev/null; then
    subjects="$(printf '%s\n' "$statements" | jq -r -s '[.[].subject[]?.digest.sha256 // empty] | unique | join(", ")')"
    echo "::error::${label} attestation for ${image} is not tied to its digest sha256:${digest} (attested subjects: ${subjects:-<none>}) or has an empty predicate"
    return 1
  fi

  echo "Verified ${label}: ${image}"
}

while IFS= read -r image; do
  [ -n "$image" ] || continue
  if [[ "$image" != *@sha256:* ]]; then
    echo "::error::Image '${image}' is not pinned by sha256 digest; cannot match its SBOM and provenance attestations"
    failures=$((failures + 1))
    continue
  fi
  digest="${image##*@sha256:}"
  check_attestation "$image" "$digest" "SBOM" "$SBOM_TYPE" || failures=$((failures + 1))
  check_attestation "$image" "$digest" "provenance" "$PROVENANCE_TYPE" || failures=$((failures + 1))
done <<< "$IMAGES"

if [ "$failures" -gt 0 ]; then
  echo "::error::${failures} SBOM/provenance check(s) failed; refusing to deploy or promote these images"
  exit 1
fi

echo "All images carry SBOM (${SBOM_TYPE}) and provenance (${PROVENANCE_TYPE}) attestations tied to their digests."
