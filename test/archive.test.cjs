'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

test('restore archive validation rejects traversal, links and device files', () => {
  const result = spawnSync(
    'python3',
    [
      '-c',
      `
import importlib.util, io, tarfile, tempfile
spec = importlib.util.spec_from_file_location('validator', 'scripts/validate-archive.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for name, kind, valid in [('./database.sql.gz', tarfile.REGTYPE, True), ('../escape', tarfile.REGTYPE, False), ('/absolute', tarfile.REGTYPE, False), ('link', tarfile.SYMTYPE, False), ('hardlink', tarfile.LNKTYPE, False), ('device', tarfile.CHRTYPE, False)]:
    with tempfile.NamedTemporaryFile(suffix='.tar.gz') as archive:
        with tarfile.open(fileobj=archive, mode='w:gz') as bundle:
            member = tarfile.TarInfo(name)
            member.type = kind
            bundle.addfile(member, io.BytesIO(b''))
        archive.flush()
        try:
            module.validate(archive.name)
        except ValueError:
            assert not valid, name
        else:
            assert valid, name
`,
    ],
    { cwd: path.resolve(__dirname, '..'), encoding: 'utf8' }
  );
  assert.equal(result.status, 0, result.error?.message || result.stderr);
});
