import subprocess


def run_probe(helper, mode, payload):
    try:
        completed = subprocess.run(
            [helper, mode, payload],
            shell=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            timeout=0.2,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return ["timeout", -1, "", ""]

    status = "ok" if completed.returncode == 0 else "error"
    return [status, completed.returncode, completed.stdout, completed.stderr]
