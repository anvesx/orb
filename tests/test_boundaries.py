"""Which code may import which (docs/design/layer-separation.md): the brain never imports voice, packages never import
an app, and the two apps never import each other. Read from the source with ast, so nothing is imported."""
import ast
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "packages/python/orb-core/src/orb_core"
AGENT = ROOT / "apps/agent/src/orb_agent"
VOICE = ("livekit", "google", "orb_core.gemini", "orb_speech", "orb_voice", "orb_agent")


def package(path: Path) -> list[str]:
    """The dotted package of a source file: the folders below `src/`."""
    parts = path.parent.parts
    return list(parts[parts.index("src") + 1:])


def imports(path: Path) -> set[str]:
    names = set()
    for node in ast.walk(ast.parse(path.read_text())):
        if isinstance(node, ast.Import):
            names |= {a.name for a in node.names}
        elif isinstance(node, ast.ImportFrom):
            base = package(path)[:len(package(path)) - node.level + 1] if node.level else []
            module = ".".join(base + ([node.module] if node.module else []))
            names.add(module)
            names |= {f"{module}.{a.name}" for a in node.names}
    return names


def files(*dirs: Path) -> list[Path]:
    return [p for d in dirs for p in sorted(d.rglob("*.py"))]


def offenders(paths, banned) -> list[str]:
    return [f"{p.relative_to(ROOT)}: {name}" for p in paths for name in sorted(imports(p))
            if any(name == b or name.startswith(b + ".") for b in banned)]


def test_the_brain_imports_no_voice():
    brain = [p for p in files(CORE) if p.name != "gemini.py"]  # gemini.py: the voice facts both apps share
    assert offenders(brain + files(ROOT / "packages/python/orb-discussion/src"), VOICE) == []


def test_packages_import_no_app():
    assert offenders(files(ROOT / "packages/python"), ("orb_agent", "orb_voice")) == []


def test_the_apps_do_not_import_each_other():
    assert offenders(files(AGENT), ("orb_voice",)) == []
    assert offenders(files(ROOT / "apps/voice-agent/src"), ("orb_agent", "orb_discussion")) == []


def test_the_brain_routes_import_no_voice():
    assert offenders([AGENT / "server.py"], ("livekit", "orb_core.gemini", "orb_agent.livekit_proxy")) == []
