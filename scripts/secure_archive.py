"""Extract trusted-hash archives without writing through links (Python 3.9+)."""
import shutil
from pathlib import Path, PurePosixPath

def safe_members(archive, prefix=None):
    members = [m for m in archive.getmembers() if not (m.isdir() and m.name in ('.', './'))]
    seen = set()
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not path.parts or (prefix and path.parts[0] != prefix):
            raise ValueError('Unsafe archive path: ' + member.name)
        if path in seen:
            raise ValueError('Duplicate archive path: ' + member.name)
        seen.add(path)
        if member.islnk():
            raise ValueError('Hard links are not supported in runtime archives')
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError('Unexpected archive member: ' + member.name)
        if member.issym() or member.islnk():
            link = PurePosixPath(member.linkname)
            target = (path.parent / link) if member.issym() else link
            depth = 0
            if link.is_absolute():
                raise ValueError('Absolute archive link')
            for part in target.parts:
                depth += -1 if part == '..' else 0 if part == '.' else 1
                if depth < (1 if prefix else 0):
                    raise ValueError('Escaping archive link')
            if prefix and target.parts[0] != prefix:
                raise ValueError('Archive link outside Python')
    return members



def extract_archive(archive, directory, prefix=None):
    """Extract into an empty private directory; never write through archive links."""
    directory = Path(directory)
    if any(directory.iterdir()):
        raise ValueError('Extraction directory must be empty')
    members = safe_members(archive, prefix)
    links = {PurePosixPath(m.name) for m in members if m.issym()}
    for member in members:
        if any(parent in links for parent in PurePosixPath(member.name).parents):
            raise ValueError('Archive entry beneath a symbolic link')
    # All writes finish before any symbolic link is created. Archive ownership,
    # setuid bits and extended attributes are deliberately not restored.
    for member in members:
        path = directory / member.name
        if member.isdir():
            path.mkdir(parents=True, exist_ok=True)
        elif member.isfile():
            path.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, path.open('xb') as target:
                shutil.copyfileobj(source, target)
            path.chmod(0o755 if member.mode & 0o111 else 0o644)
    for member in members:
        if member.issym():
            path = directory / member.name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(member.linkname)
    root = (directory / prefix).resolve() if prefix else directory.resolve()
    for member in members:
        if member.issym():
            try:
                resolved = (directory / member.name).resolve(strict=True)
                resolved.relative_to(root)
            except (ValueError, OSError, RuntimeError) as error:
                raise ValueError('Invalid or escaping archive link: ' + member.name) from error
