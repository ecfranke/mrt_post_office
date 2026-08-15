"""M Post Office, based on the Modoboa mail platform."""

from importlib.metadata import version, PackageNotFoundError

try:
    __version__ = version("m-post-office")
except PackageNotFoundError:
    try:
        # Compatibility with installations made before the project rebrand.
        __version__ = version("modoboa")
    except PackageNotFoundError:
        __version__ = None


def modoboa_admin():
    from modoboa.core.commands import handle_command_line

    handle_command_line()
