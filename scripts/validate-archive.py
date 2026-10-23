#!/usr/bin/env python3
"""Reject archive members that could escape the restore directory."""
import sys
import tarfile
from pathlib import PurePosixPath


def validate(archive):
    with tarfile.open(archive, 'r:gz') as bundle:
        for member in bundle:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError(f'unsafe archive path: {member.name}')
            if not (member.isfile() or member.isdir()):
                raise ValueError(f'unsupported archive member: {member.name}')


if __name__ == '__main__':
    try:
        validate(sys.argv[1])
    except (OSError, ValueError, tarfile.TarError) as error:
        sys.exit(str(error))
