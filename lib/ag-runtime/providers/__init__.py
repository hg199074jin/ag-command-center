"""Provider adapters。"""

from .base import ProviderAdapter, run_capture
from .claude import ClaudeAdapter
from .codex import CodexAdapter

ADAPTERS = {"codex": CodexAdapter, "claude": ClaudeAdapter}


def get_adapter(name):
    cls = ADAPTERS.get(name)
    return cls() if cls else None
