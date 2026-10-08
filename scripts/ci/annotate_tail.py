"""Turn the end of a failed build log into GitHub annotations.

  annotate_tail.py <log file> <title>

Job logs of GitHub Actions can only be read when signed in; annotations are
public. So a failure shows the lines that matter to anyone who opens the run:
the error lines of the whole log, then its last lines.
"""
import re
import sys
from pathlib import Path

ERRORS = re.compile(r"(^E: |^ERROR|error:|dpkg: error|Segmentation fault|uncaught target signal"
                    r"|Errors were encountered|returned an error code|returned error exit status"
                    r"|BUILD FAILED|No such file|Unable to locate|unmet dependencies)", re.I)
CHUNK = 3500


def emit(title, lines):
    text = "\n".join(line[:300] for line in lines)[-CHUNK:]
    text = text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
    print(f"::error title={title}::{text}")


def main():
    path, title = Path(sys.argv[1]), sys.argv[2]
    if not path.is_file():
        print(f"::error title={title}::no log at {path}")
        return
    lines = [line for line in path.read_text(errors="replace").splitlines() if line.strip()]
    errors = [line for line in lines if ERRORS.search(line)]
    if errors:
        emit(f"{title}: error lines", errors[-25:])
    emit(f"{title}: last lines", lines[-45:])


if __name__ == "__main__":
    main()
