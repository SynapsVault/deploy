const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const repo = path.resolve(__dirname, '..');
const script = path.join(repo, 'scripts/verify-image-attestations.sh');

function envelope(subjectDigest, predicate = { builder: { id: 'https://github.com/SynapsVault/backend' } }) {
    const statement = {
        _type: 'https://in-toto.io/Statement/v0.1',
        subject: [{ name: 'ghcr.io/synapsvault/backend', digest: { sha256: subjectDigest } }],
        predicateType: 'https://example.com/predicate',
        predicate,
    };
    return JSON.stringify({
        payloadType: 'application/vnd.in-toto+json',
        payload: Buffer.from(JSON.stringify(statement)).toString('base64'),
        signatures: [],
    });
}

// `outputs` maps a cosign `--type` value to { exit, stdout }.
function withFakeTools({ images, outputs = {} }, env = {}) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'verify-att-'));
    fs.writeFileSync(
        path.join(dir, 'kubectl'),
        `#!/usr/bin/env bash\nprintf '%s\\n' ${JSON.stringify(images.join('\n'))}\n`,
    );
    fs.writeFileSync(
        path.join(dir, 'yq'),
        "#!/usr/bin/env bash\ncat | grep -E 'image:' | sed -E 's/.*image: *//' | sort -u\n",
    );
    for (const [type, { exit = 0, stdout = '' }] of Object.entries(outputs)) {
        fs.writeFileSync(path.join(dir, `cosign-${type}.out`), stdout ? `${stdout}\n` : '');
        fs.writeFileSync(path.join(dir, `cosign-${type}.exit`), String(exit));
    }
    fs.writeFileSync(
        path.join(dir, 'cosign'),
        [
            '#!/usr/bin/env bash',
            `echo "$@" >> "${dir}/cosign-calls.log"`,
            'type=""; prev=""',
            'for arg in "$@"; do [ "$prev" = "--type" ] && type="$arg"; prev="$arg"; done',
            `if [ ! -f "${dir}/cosign-$type.exit" ]; then echo "Error: no matching attestations" >&2; exit 1; fi`,
            `cat "${dir}/cosign-$type.out"`,
            `exit "$(cat "${dir}/cosign-$type.exit")"`,
            '',
        ].join('\n'),
    );
    for (const name of ['kubectl', 'yq', 'cosign']) {
        fs.chmodSync(path.join(dir, name), 0o755);
    }

    const result = spawnSync('bash', [script, 'overlays/production'], {
        cwd: repo,
        env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, ...env },
        encoding: 'utf8',
    });
    return {
        status: result.status,
        output: `${result.stdout}${result.stderr}`,
        calls: fs.existsSync(path.join(dir, 'cosign-calls.log'))
            ? fs.readFileSync(path.join(dir, 'cosign-calls.log'), 'utf8')
            : '',
    };
}

const env = {
    COSIGN_IDENTITY: 'https://github.com/SynapsVault/backend/.github/workflows/build.yml@refs/heads/main',
    COSIGN_OIDC_ISSUER: 'https://token.actions.githubusercontent.com',
};

const digest = 'd'.repeat(64);
const image = `ghcr.io/synapsvault/backend@sha256:${digest}`;

test('fails when identity or issuer is missing', () => {
    const result = withFakeTools({ images: [`image: ${image}`] }, {
        COSIGN_IDENTITY: '',
        COSIGN_OIDC_ISSUER: '',
    });
    assert.equal(result.status, 1);
    assert.match(result.output, /COSIGN_IDENTITY and COSIGN_OIDC_ISSUER/);
    assert.equal(result.calls, '');
});

test('rejects unpinned images', () => {
    const result = withFakeTools({ images: ['image: taskapp-backend:latest'] }, env);
    assert.equal(result.status, 1);
    assert.match(result.output, /not pinned by sha256 digest/);
    assert.equal(result.calls, '');
});

test('passes when SBOM and provenance attestations reference the image digest', () => {
    const result = withFakeTools(
        {
            images: [`image: ${image}`],
            outputs: {
                spdxjson: { stdout: envelope(digest, { spdxVersion: 'SPDX-2.3' }) },
                slsaprovenance: { stdout: envelope(digest) },
            },
        },
        env,
    );
    assert.equal(result.status, 0, result.output);
    assert.match(result.calls, /--type spdxjson/);
    assert.match(result.calls, /--type slsaprovenance/);
    assert.match(result.calls, /--certificate-identity/);
    assert.match(result.calls, /--certificate-oidc-issuer/);
});

test('blocks deploy when the provenance attestation is missing', () => {
    const result = withFakeTools(
        {
            images: [`image: ${image}`],
            outputs: { spdxjson: { stdout: envelope(digest, { spdxVersion: 'SPDX-2.3' }) } },
        },
        env,
    );
    assert.equal(result.status, 1);
    assert.match(result.output, /Missing or unverifiable provenance attestation/);
    assert.match(result.output, /no matching attestations/);
});

test('blocks deploy when an attestation is tied to a different digest', () => {
    const other = 'e'.repeat(64);
    const result = withFakeTools(
        {
            images: [`image: ${image}`],
            outputs: {
                spdxjson: { stdout: envelope(other, { spdxVersion: 'SPDX-2.3' }) },
                slsaprovenance: { stdout: envelope(digest) },
            },
        },
        env,
    );
    assert.equal(result.status, 1);
    assert.match(result.output, new RegExp(`SBOM attestation for .* is not tied to its digest sha256:${digest}`));
    assert.match(result.output, new RegExp(`attested subjects: ${other}`));
});

test('honours overridden predicate types', () => {
    const result = withFakeTools(
        {
            images: [`image: ${image}`],
            outputs: {
                cyclonedx: { stdout: envelope(digest, { bomFormat: 'CycloneDX' }) },
                slsaprovenance1: { stdout: envelope(digest) },
            },
        },
        { ...env, SBOM_PREDICATE_TYPE: 'cyclonedx', PROVENANCE_PREDICATE_TYPE: 'slsaprovenance1' },
    );
    assert.equal(result.status, 0, result.output);
    assert.match(result.calls, /--type cyclonedx/);
    assert.match(result.calls, /--type slsaprovenance1/);
});
