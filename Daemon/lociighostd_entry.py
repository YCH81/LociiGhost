"""PyInstaller entry-point wrapper.

PyInstaller treats the script passed on its CLI as a top-level
module — there's no parent package, so any `from .` relative
imports inside that script will fail at runtime with
`ImportError: attempted relative import with no known parent
package`. The package's own `lociighostd/__main__.py` has plenty
of those, so we don't point PyInstaller at it directly.

Instead, build-daemon.sh points PyInstaller at THIS file, which
sits OUTSIDE the package and does an absolute import of the
package's `main()`. That way `lociighostd` is imported as a real
package and its internal relative imports resolve correctly.
"""

from __future__ import annotations

import sys

from lociighostd.__main__ import main


if __name__ == "__main__":
    raise SystemExit(main())
