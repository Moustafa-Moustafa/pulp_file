import logging
import os

from collections import namedtuple
from gettext import gettext as _
from urllib.parse import urlparse, urlunparse

from celery import shared_task
from django.db.models import Q

from pulpcore.plugin.models import Artifact, RepositoryVersion, Repository
from pulpcore.plugin.changeset import (
    BatchIterator,
    ChangeSet,
    PendingArtifact,
    PendingContent,
    SizedIterable)
from pulpcore.plugin.tasking import UserFacingTask, WorkingDirectory

from pulp_file.app.models import FileContent, FileImporter
from pulp_file.manifest import Manifest


log = logging.getLogger(__name__)


# The natural key.
Key = namedtuple('Key', ('path', 'digest'))

# The set of Key to be added and removed.
Delta = namedtuple('Delta', ('additions', 'removals'))


@shared_task(base=UserFacingTask)
def synchronize(importer_pk, repository_pk):
    """
    Create a new version of the repository that is synchronized with the remote
    as specified by the importer.

    Args:
        importer_pk (str): The importer PK.
        repository_pk (str): The repository PK.

    Raises:
        ValueError: When feed_url is empty.
    """
    importer = FileImporter.objects.get(pk=importer_pk)
    repository = Repository.objects.get(pk=repository_pk)
    base_version = RepositoryVersion.latest(repository)

    if not importer.feed_url:
        raise ValueError(_('An importer must have a feed_url specified to synchronize.'))

    with WorkingDirectory():
        with RepositoryVersion.create(repository) as new_version:
            log.info(
                _('Synchronizing: repository=%(r)s importer=%(p)s'),
                {
                    'r': repository.name,
                    'p': importer.name
                })
            manifest = fetch_manifest(importer)
            content = fetch_content(base_version)
            delta = find_delta(manifest, content)
            additions = build_additions(importer, manifest, delta)
            removals = build_removals(base_version, delta)
            changeset = ChangeSet(
                importer=importer,
                repository_version=new_version,
                additions=additions,
                removals=removals)
            for report in changeset.apply():
                if not log.isEnabledFor(logging.DEBUG):
                    continue
                log.debug(
                    _('Applied: repository=%(r)s importer=%(p)s change:%(c)s'),
                    {
                        'r': repository.name,
                        'p': importer.name,
                        'c': report,
                    })


def fetch_manifest(importer):
    """
    Fetch (download) the manifest.

    Args:
        importer (FileImporter): An importer.
    """
    downloader = importer.get_downloader(importer.feed_url)
    downloader.fetch()
    return Manifest(downloader.path)


def fetch_content(base_version):
    """
    Fetch the FileContent contained in the (base) repository version.

    Args:
        base_version (RepositoryVersion): A repository version.

    Returns:
        set: A set of Key contained in the (base) repository version.
    """
    content = set()
    if base_version:
        for file in FileContent.objects.filter(pk__in=base_version.content):
            key = Key(path=file.path, digest=file.digest)
            content.add(key)
    return content


def find_delta(manifest, content, mirror=True):
    """
    Find the content that needs to be added and removed.

    Args:
        manifest (Manifest): The downloaded manifest.
        content: (set): The set of natural keys for content contained in the (base)
            repository version.
        mirror (bool): The delta should include changes needed to ensure the content
            contained within the pulp repository is exactly the same as the
            content contained within the remote repository.

    Returns:
        Delta: The set of Key to be added and removed.
    """
    remote_content = set(
        [
            Key(path=e.path, digest=e.digest) for e in manifest.read()
        ])
    additions = (remote_content - content)
    if mirror:
        removals = (content - remote_content)
    else:
        removals = set()
    return Delta(additions, removals)


def build_additions(importer, manifest, delta):
    """
    Build the content to be added.

    Args:
        importer (FileImporter): An importer.
        manifest (Manifest): The downloaded manifest.
        delta (Delta): The set of Key to be added and removed.

    Returns:
        SizedIterable: The PendingContent to be added to the repository.
    """
    def generate():
        for entry in manifest.read():
            key = Key(path=entry.path, digest=entry.digest)
            if key not in delta.additions:
                continue
            path = os.path.join(root_dir, entry.path)
            url = urlunparse(parsed_url._replace(path=path))
            file = FileContent(path=entry.path, digest=entry.digest)
            artifact = Artifact(size=entry.size, sha256=entry.digest)
            content = PendingContent(
                file,
                artifacts={
                    PendingArtifact(artifact, url, entry.path)
                })
            yield content
    parsed_url = urlparse(importer.feed_url)
    root_dir = os.path.dirname(parsed_url.path)
    return SizedIterable(generate(), len(delta.additions))


def build_removals(base_version, delta):
    """
    Build the content to be removed.

    Args:
        base_version (RepositoryVersion):  The base repository version.
        delta (Delta): The set of Key to be added and removed.

    Returns:
        SizedIterable: The FileContent to be removed from the repository.
    """
    def generate():
        for removals in BatchIterator(delta.removals):
            q = Q()
            for key in removals:
                q |= Q(filecontent__path=key.path, filecontent__digest=key.digest)
            q_set = base_version.content.filter(q)
            q_set = q_set.only('id')
            for file in q_set:
                yield file
    return SizedIterable(generate(), len(delta.removals))
