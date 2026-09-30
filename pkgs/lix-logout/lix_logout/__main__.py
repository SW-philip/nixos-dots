from __future__ import annotations

import sys


def main(argv=None) -> int:
    from .app import LogoutApp
    app = LogoutApp()
    return app.run(argv or [])


if __name__ == "__main__":
    sys.exit(main())
