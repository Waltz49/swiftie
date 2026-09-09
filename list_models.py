#!/usr/bin/env python3
"""Tools > Debug > List Models — browse cached Hugging Face and LM Studio models."""

from __future__ import annotations

import json
from functools import lru_cache
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, FrozenSet, Iterable, List, Optional, Set, Tuple

from huggingface_hub import scan_cache_dir

from PySide6.QtCore import QEvent, QObject, QThread, QSize, Qt, Signal
from PySide6.QtGui import QColor, QFont, QGuiApplication, QIcon, QImage, QPixmap
from PySide6.QtWidgets import (
    QAbstractItemView,
    QDialog,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMenu,
    QMessageBox,
    QProgressDialog,
    QPushButton,
    QSizePolicy,
    QTableWidget,
    QTableWidgetItem,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)

from theme.theme_base import asset_path
from theme.theme_service import get_active_theme
from utils import (
    normalize_path_for_display,
    present_auxiliary_dialog,
    raise_dialog_without_space_hop,
)
from widgets.filter_clear_button import clear_filter_icon, configure_filter_clear_button

_WEIGHT_SUFFIXES = (".safetensors", ".bin", ".pt", ".ckpt")
_PIPELINE_MARKERS = (
    "diffusion_pytorch",
    "scheduler_config",
    "/unet/",
    "/text_encoder/",
    "/transformer/",
    "/vae/",
)
_IMAGE_REPO_HINTS = (
    "sdxl",
    "stable-diffusion",
    "diffusers",
    "realvis",
    "realistic_vision",
    "/realistic_",
    "sana",
    "z-image",
    "anythingfurry",
    "anything-v",
    "turbo",
    "openflux",
)
_FLUX_BASE_HINTS = ("flux.1", "flux.2", "flux1", "flux2", "/flux-", "_flux_")
_LORA_FILENAME_HINTS = ("lora", "adapter_model", "pytorch_lora_weights", "lycoris")
_INCIDENTAL_SUFFIXES = (
    ".md",
    ".txt",
    ".webp",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".svg",
    ".mp4",
    ".html",
    ".csv",
    ".zip",
)
_INCIDENTAL_EXACT = frozenset(
    {
        ".gitattributes",
        "readme.md",
        "license",
        "license.md",
        "license.txt",
        "usage.md",
        "config.toml",
    }
)
_LORA_MAX_SINGLE_WEIGHT_BYTES = 2_000_000_000
_IMAGE_NAME_HINT_MIN_BYTES = 500_000_000
_FLUX_NAME_IMAGE_MIN_BYTES = 1_000_000_000

_VAE_RE = re.compile(r"(?:^|/|-)vae(?:$|/|-)")


def repo_files(repo) -> Tuple[Set[str], Dict[str, str]]:
    names: Set[str] = set()
    paths: Dict[str, str] = {}
    for rev in repo.revisions:
        for f in rev.files:
            key = f.file_name.lower()
            names.add(key)
            paths[key] = f.file_path
    return names, paths


def _load_json(path: Optional[str]):
    if not path:
        return None
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def load_config_jsons(paths: Dict[str, str]) -> List[dict]:
    configs: List[dict] = []
    for name, path in paths.items():
        if name == "config.json":
            cfg = _load_json(path)
            if cfg:
                configs.append(cfg)
    return configs


def weight_file_names(names: Iterable[str]) -> List[str]:
    return sorted(n for n in names if n.endswith(_WEIGHT_SUFFIXES))


def is_incidental_file(name: str) -> bool:
    lower = name.lower()
    if lower in _INCIDENTAL_EXACT:
        return True
    base = lower.rsplit("/", 1)[-1]
    if base in _INCIDENTAL_EXACT:
        return True
    if base.endswith(_INCIDENTAL_SUFFIXES):
        return True
    if lower.startswith(("images/", "assets/", "preview/")):
        return True
    return False


def has_diffusers_pipeline(names: Set[str]) -> bool:
    if "model_index.json" in names:
        return True
    return any(
        marker in name for name in names for marker in _PIPELINE_MARKERS
    )


def _is_vae_repo(repo_lower: str) -> bool:
    return bool(_VAE_RE.search(repo_lower))


def is_standalone_vae(names: Set[str], configs: List[dict], repo_lower: str) -> bool:
    if _is_vae_repo(repo_lower):
        return True
    return (
        any(cfg.get("_class_name") == "AutoencoderKL" for cfg in configs)
        and len(names) <= 3
        and "model_index.json" not in names
    )


@lru_cache(maxsize=1)
def known_lora_repo_ids() -> FrozenSet[str]:
    try:
        from imagegen_plugins.lora_catalog import LORA_CATALOG

        return frozenset(
            e.repo_id.lower()
            for e in LORA_CATALOG.values()
            if e.repo_id
        )
    except Exception:
        return frozenset()


def is_known_lora_repo(repo_id: str) -> bool:
    return repo_id.lower() in known_lora_repo_ids()


def is_in_app_lora_cache(repo_id: str) -> bool:
    slug = repo_id.replace("/", "__")
    for root in (
        Path.home() / ".cache" / "image_browser" / "mflux_loras",
        Path.home() / ".cache" / "mflux_loras",
    ):
        cache_dir = root / slug
        if cache_dir.is_dir() and any(cache_dir.glob("*.safetensors")):
            return True
    return False


def weight_names_suggest_lora(weight_names: List[str]) -> bool:
    return any(
        hint in w for w in weight_names for hint in _LORA_FILENAME_HINTS
    )


def config_suggests_full_model(configs: List[dict]) -> bool:
    for cfg in configs:
        class_name = str(cfg.get("_class_name", ""))
        if any(
            k in class_name
            for k in ("UNet", "Transformer2D", "Pipeline", "AutoencoderKLFlux")
        ):
            return True
    return False


def looks_like_lora_adapter(
    names: Set[str],
    configs: List[dict],
    repo_id: str,
    repo_lower: str,
    size_on_disk: int,
) -> bool:
    if has_diffusers_pipeline(names):
        return False
    if is_known_lora_repo(repo_id) or is_in_app_lora_cache(repo_id):
        return True
    if "lora" in repo_lower:
        return True

    weights = weight_file_names(names)
    if not weights:
        return False

    if weight_names_suggest_lora(weights):
        return True

    if config_suggests_full_model(configs):
        return False

    if "adapter_config.json" in names:
        return True

    non_incidental = {n for n in names if not is_incidental_file(n)}
    if len(weights) == 1 and len(non_incidental) <= 2:
        if size_on_disk < _LORA_MAX_SINGLE_WEIGHT_BYTES:
            return True

    return False


def name_suggests_image_checkpoint(repo_lower: str, size_on_disk: int) -> bool:
    if size_on_disk < _IMAGE_NAME_HINT_MIN_BYTES:
        return False
    if any(h in repo_lower for h in _IMAGE_REPO_HINTS):
        return True
    if any(h in repo_lower for h in _FLUX_BASE_HINTS):
        return True
    if "flux" in repo_lower and size_on_disk >= _FLUX_NAME_IMAGE_MIN_BYTES:
        return True
    return False


def infer_model_kind(repo) -> str:
    if repo.repo_type != "model":
        return repo.repo_type

    names, paths = repo_files(repo)
    repo_lower = repo.repo_id.lower()
    configs = load_config_jsons(paths)
    size_on_disk = int(getattr(repo, "size_on_disk", 0) or 0)

    if "controlnet" in repo_lower or any("controlnet" in n for n in names):
        return "ControlNet"
    if (
        "ip-adapter" in repo_lower
        or "ip_adapter" in repo_lower
        or any("ip-adapter" in n or "ip_adapter" in n for n in names)
    ):
        return "Adapter"
    if any(x in repo_lower for x in ("tts", "whisper", "speech", "kyutai/")):
        return "Audio"
    if is_standalone_vae(names, configs, repo_lower):
        return "VAE"

    if looks_like_lora_adapter(names, configs, repo.repo_id, repo_lower, size_on_disk):
        return "LoRA"

    if has_diffusers_pipeline(names):
        return "image"
    if any(
        marker in n
        for n in names
        for marker in ("diffusion_pytorch", "scheduler_config", "/unet/", "/transformer/")
    ):
        return "image"
    if config_suggests_full_model(configs):
        return "image"
    if name_suggests_image_checkpoint(repo_lower, size_on_disk):
        return "image"

    for cfg in configs:
        model_type = str(cfg.get("model_type", ""))
        archs = cfg.get("architectures") or []
        if model_type == "clip" or any("CLIP" in a for a in archs):
            return "CLIP"

    for cfg in configs:
        archs = cfg.get("architectures") or []
        model_type = str(cfg.get("model_type", ""))
        if any("CausalLM" in a or "ForConditionalGeneration" in a for a in archs):
            return "text"
        if model_type in ("llama", "qwen2", "qwen3", "mistral", "gemma", "phi", "gpt2", "bloom"):
            return "text"

    weights = weight_file_names(names)
    non_incidental = {n for n in names if not is_incidental_file(n)}
    if (
        len(weights) == 1
        and len(non_incidental) <= 2
        and size_on_disk < _LORA_MAX_SINGLE_WEIGHT_BYTES
    ):
        return "LoRA"

    return "other"

_FOLDER_ROLE = Qt.ItemDataRole.UserRole + 1
_FULL_NAME_ROLE = Qt.ItemDataRole.UserRole + 2
_DELETE_BTN_SIZE = 24


def _display_model_name(full_name: str, strip_org_prefix: bool) -> str:
    if strip_org_prefix and "/" in full_name:
        return full_name.split("/", 1)[1]
    return full_name


def _full_name_from_item(item: QTableWidgetItem) -> str:
    stored = item.data(_FULL_NAME_ROLE)
    if stored:
        return str(stored)
    return item.text()


def _get_saved_lm_model_key() -> str:
    try:
        from imagegen_plugins.lmstudio_caption import _get_last_lm_model_key

        return _get_last_lm_model_key() or ""
    except Exception:
        return ""


def _delete_button_stylesheet() -> str:
    t = get_active_theme()
    icon_url = f"url({asset_path('trash_icon.png')})"
    hover_url = f"url({asset_path('trash_icon_hover.png')})"
    sz = _DELETE_BTN_SIZE
    return f"""
        QPushButton {{
            background-color: {t.dialog_background_hex};
            border: 1px solid {t.border_default_hex};
            border-radius: 3px;
            padding: 0px;
            min-width: {sz}px;
            max-width: {sz}px;
            min-height: {sz}px;
            max-height: {sz}px;
            image: {icon_url};
        }}
        QPushButton:focus {{
            border: 1px solid {t.current_image_border_color_hex};
            outline: none;
        }}
        QPushButton:hover {{
            background-color: {t.tab_button_hover_bg_hex};
            border: 1px solid {t.tab_button_hover_bg_hex};
            image: {hover_url};
        }}
        QPushButton:pressed {{
            background-color: {t.sidebar_splitter_handle_hex};
        }}
        QPushButton:disabled {{
            opacity: 0.35;
        }}
    """


def _make_delete_button(on_click) -> QPushButton:
    btn = QPushButton()
    btn.setToolTip("Delete")
    btn.setStyleSheet(_delete_button_stylesheet())
    btn.setFixedSize(_DELETE_BTN_SIZE, _DELETE_BTN_SIZE)
    btn.clicked.connect(on_click)
    return btn

SCRIPT_DIR = Path(__file__).resolve().parent
LM_MODEL_EXTENSIONS = {".gguf", ".safetensors", ".bin", ".pt"}


def resolve_lmstudio_models_dir() -> Path:
    """Return the LM Studio models directory (first existing candidate)."""
    candidates = [
        Path.home() / ".cache" / "lm-studio" / "models",
        Path.home() / ".lmstudio" / "models",
        SCRIPT_DIR / "cache" / "lmstudio" / "models",
    ]
    for path in candidates:
        if path.is_dir():
            return path
    return candidates[0]

_QUANT_RE = re.compile(
    r"(?:^|[-_.])((?:q\d+(?:_[a-z0-9]+)+|q\d+_[0-9]|fp16|bf16|f16|f32))(?:[-_.]|$)",
    re.IGNORECASE,
)


class NumericSortItem(QTableWidgetItem):
    """Table item that sorts by a numeric value instead of display text."""

    def __init__(self, text: str, sort_value):
        super().__init__(text)
        self._sort_value = sort_value

    def __lt__(self, other):
        if isinstance(other, NumericSortItem):
            return self._sort_value < other._sort_value
        return super().__lt__(other)


@dataclass(frozen=True)
class LMStudioModel:
    path: Path
    model_id: str
    filename: str
    format: str
    quant: str
    kind: str
    size_bytes: int
    mtime: float


def _format_size(size_bytes: int) -> str:
    if size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    if size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / (1024 * 1024):.1f} MB"
    return f"{size_bytes / (1024 * 1024 * 1024):.1f} GB"


def _path_mtime(path: Path) -> float | None:
    try:
        return path.stat().st_mtime
    except OSError:
        return None


def _most_recent_mtime(*paths: Path) -> float:
    mtimes = [t for p in paths if p for t in (_path_mtime(p),) if t is not None]
    return max(mtimes) if mtimes else 0.0


def _format_mtime(ts: float) -> str:
    if ts <= 0:
        return "—"
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def hf_repo_most_recent_mtime(repo) -> float:
    """Return the latest mtime among the repo cache dir and its cached files."""
    paths: list[Path] = []
    cache_dir = hf_repo_cache_dir(repo)
    if cache_dir:
        paths.append(cache_dir)
    for rev in repo.revisions:
        for f in rev.files:
            paths.append(Path(f.file_path))
    return _most_recent_mtime(*paths)


def lm_model_most_recent_mtime(path: Path) -> float:
    """Return the latest mtime of the model file and its containing directory."""
    return _most_recent_mtime(path, path.parent)


def infer_lm_quantization(filename: str) -> str:
    match = _QUANT_RE.search(filename)
    if not match:
        return ""
    return match.group(1).upper().replace(".", "_")


def infer_lm_model_kind(name_lower: str) -> str:
    if "lora" in name_lower or "adapter" in name_lower:
        return "LoRA"
    if "embed" in name_lower:
        return "Embedding"
    if "vision" in name_lower or "mmproj" in name_lower or "clip" in name_lower:
        return "Vision"
    if "whisper" in name_lower or "speech" in name_lower:
        return "Audio"
    return "LLM"


def _lm_model_id(rel_path: Path) -> str:
    parts = rel_path.parts
    if len(parts) >= 3:
        return f"{parts[0]}/{parts[1]}"
    if len(parts) == 2:
        return parts[0]
    return rel_path.stem


def hf_repo_cache_dir(repo) -> Path | None:
    """Return the Hugging Face hub cache folder for a cached repo."""
    for rev in repo.revisions:
        for f in rev.files:
            path = Path(f.file_path)
            for parent in path.parents:
                if parent.name.startswith("models--"):
                    return parent
    return None


def _local_lora_cache_roots() -> tuple[Path, ...]:
    from imagegen_plugins.lora_entry import DEFAULT_CACHE, _ALT_CACHE

    return (DEFAULT_CACHE, _ALT_CACHE)


def scan_local_lora_files() -> list[Path]:
    """Return .safetensors files under app LoRA cache dirs (not Hugging Face hub)."""
    seen: set[str] = set()
    paths: list[Path] = []
    for root in _local_lora_cache_roots():
        if not root.is_dir():
            continue
        for path in root.rglob("*.safetensors"):
            if not path.is_file():
                continue
            try:
                if path.stat().st_size < 1024:
                    continue
            except OSError:
                continue
            try:
                key = str(path.resolve())
            except OSError:
                key = str(path)
            if key in seen:
                continue
            seen.add(key)
            paths.append(path)
    return sorted(paths, key=lambda p: p.name.lower())


def _lora_id_for_local_file(path: Path, settings: dict) -> Optional[str]:
    from imagegen_plugins.lora_catalog import catalog_cache_path, merged_lora_catalog
    from imagegen_plugins.lora_user_entries import (
        _entry_path_candidates,
        same_lora_file,
        user_lora_entries_from_settings,
    )

    for lid, entry in user_lora_entries_from_settings(settings).items():
        for cand in _entry_path_candidates(entry):
            if same_lora_file(path, cand):
                return lid

    for lid, entry in merged_lora_catalog(settings).items():
        cache_path = catalog_cache_path(entry)
        if cache_path is not None and same_lora_file(path, cache_path):
            return lid
        local_raw = str(entry.local_path or "").strip()
        if local_raw and same_lora_file(path, Path(local_raw).expanduser()):
            return lid
    return None


def _lora_model_assignment_lines(lora_id: str, settings: dict) -> list[str]:
    from imagegen_plugins.lora_catalog import get_lora_entry
    from imagegen_plugins.lora_catalog_settings import hidden_lora_ids_for_model
    from imagegen_plugins.lora_model_registry import (
        LORA_SETTINGS_MODEL_ORDER,
        entry_matches_lora_model,
        lora_settings_model,
    )

    entry = get_lora_entry(lora_id, settings)
    if entry is None:
        return []

    lines: list[str] = []
    for model_key in LORA_SETTINGS_MODEL_ORDER:
        if not entry_matches_lora_model(entry, model_key, settings=settings):
            continue
        meta = lora_settings_model(model_key)
        label = meta.display_name if meta else model_key
        label = _display_model_name(label, strip_org_prefix=True)
        if lora_id in hidden_lora_ids_for_model(model_key, settings):
            lines.append(f"{label} (hidden)")
        else:
            lines.append(label)
    return lines


def _local_lora_row_tooltip(path: Path, lora_id: Optional[str], settings: dict) -> str:
    parts: list[str] = [normalize_path_for_display(str(path))]
    if lora_id:
        assignment_lines = _lora_model_assignment_lines(lora_id, settings)
        parts.append("")
        if assignment_lines:
            parts.extend(assignment_lines)
        else:
            parts.append("Not assigned to any model")
    else:
        parts.append("")
        parts.append("Not in LoRA catalog")
    return "\n".join(parts)


def _lora_unhidden_on_any_model(lora_id: str, settings: dict) -> bool:
    from imagegen_plugins.lora_catalog import get_lora_entry
    from imagegen_plugins.lora_catalog_settings import hidden_lora_ids_for_model
    from imagegen_plugins.lora_model_registry import (
        LORA_SETTINGS_MODEL_ORDER,
        entry_matches_lora_model,
    )

    entry = get_lora_entry(lora_id, settings)
    if entry is None:
        return False
    for model_key in LORA_SETTINGS_MODEL_ORDER:
        if not entry_matches_lora_model(entry, model_key, settings=settings):
            continue
        if lora_id not in hidden_lora_ids_for_model(model_key, settings):
            return True
    return False


@dataclass(frozen=True)
class LocalLoraFile:
    path: Path
    display_name: str
    lora_id: Optional[str]
    size_bytes: int
    mtime: float
    unhidden: bool
    model_tooltip: str


def scan_local_lora_rows(settings: dict) -> list[LocalLoraFile]:
    from imagegen_plugins.lora_catalog import get_lora_entry

    rows: list[LocalLoraFile] = []
    for path in scan_local_lora_files():
        lora_id = _lora_id_for_local_file(path, settings)
        if lora_id:
            entry = get_lora_entry(lora_id, settings)
            display_name = entry.display_name if entry else path.stem
        else:
            display_name = path.stem
        try:
            stat = path.stat()
            size_bytes = stat.st_size
            mtime = stat.st_mtime
        except OSError:
            size_bytes = 0
            mtime = 0.0
        unhidden = bool(lora_id and _lora_unhidden_on_any_model(lora_id, settings))
        model_tooltip = _local_lora_row_tooltip(path, lora_id, settings)
        rows.append(
            LocalLoraFile(
                path=path,
                display_name=display_name,
                lora_id=lora_id,
                size_bytes=size_bytes,
                mtime=mtime,
                unhidden=unhidden,
                model_tooltip=model_tooltip,
            )
        )
    return rows


def scan_lmstudio_models() -> list[LMStudioModel]:
    models_dir = resolve_lmstudio_models_dir()
    if not models_dir.is_dir():
        return []

    models: list[LMStudioModel] = []
    for path in sorted(models_dir.rglob("*")):
        if not path.is_file():
            continue
        suffix = path.suffix.lower()
        if suffix not in LM_MODEL_EXTENSIONS:
            continue
        rel = path.relative_to(models_dir)
        name_lower = str(rel).lower()
        models.append(
            LMStudioModel(
                path=path,
                model_id=_lm_model_id(rel),
                filename=path.name,
                format=suffix.lstrip(".").upper(),
                quant=infer_lm_quantization(path.name),
                kind=infer_lm_model_kind(name_lower),
                size_bytes=path.stat().st_size,
                mtime=lm_model_most_recent_mtime(path),
            )
        )
    return models


class ListModelsWindow(QDialog):
    def __init__(
        self,
        parent=None,
    ):
        super().__init__(parent)
        self.setWindowTitle("Cached Models")
        self.resize(960, 520)
        self.setWindowFlags(
            Qt.WindowType.Dialog
            | Qt.WindowType.WindowTitleHint
            | Qt.WindowType.WindowSystemMenuHint
            | Qt.WindowType.WindowCloseButtonHint
        )
        self.setWindowModality(Qt.WindowModality.NonModal)

        layout = QVBoxLayout(self)

        header = QHBoxLayout()

        self.status_label = QLabel()
        header.addWidget(self.status_label, stretch=1)

        refresh_btn = QPushButton("Refresh")
        refresh_btn.clicked.connect(self.load_models)
        header.addWidget(refresh_btn)

        filter_widget = QWidget()
        filter_layout = QHBoxLayout(filter_widget)
        filter_layout.setContentsMargins(0, 0, 0, 0)
        filter_layout.setSpacing(4)

        self.filter_edit = QLineEdit()
        self.filter_edit.setPlaceholderText("Filter models…")
        self.filter_edit.setMinimumWidth(220)
        self.filter_edit.textChanged.connect(self._apply_filter)

        self.filter_clear_btn = QPushButton()
        self.filter_clear_btn.setIcon(clear_filter_icon())
        self.filter_clear_btn.setIconSize(QSize(18, 18))
        self.filter_clear_btn.setFixedSize(24, 24)
        self.filter_clear_btn.setFlat(True)
        self.filter_clear_btn.setToolTip("Clear filter")
        self.filter_clear_btn.setEnabled(False)
        self.filter_clear_btn.clicked.connect(self.filter_edit.clear)
        self.filter_edit.textChanged.connect(
            lambda text: self.filter_clear_btn.setEnabled(bool(text))
        )

        filter_layout.addWidget(self.filter_edit)
        filter_layout.addWidget(self.filter_clear_btn)
        header.addWidget(filter_widget)

        self.format_btn = QPushButton("Format")
        self.format_btn.setCheckable(True)
        self.format_btn.setToolTip(
            "Toggle short names (hide publisher prefix before the slash)"
        )
        self.format_btn.toggled.connect(self._on_format_toggled)
        header.addWidget(self.format_btn)

        layout.addLayout(header)

        self._strip_org_prefix = False
        self.tabs = QTabWidget()
        self.tabs.setTabPosition(QTabWidget.TabPosition.West)
        self.hf_table = self._create_table(["Filename", "Type", "Size", "Modified", ""])
        self.lms_table = self._create_table(
            ["Model", "Type", "Format", "Quant", "Size", "Modified", ""]
        )
        self.lora_table = self._create_table(["Name", "Visible", "Size", "Modified"])
        self.tabs.addTab(self.hf_table, "Hugging Face")
        self.tabs.addTab(self.lms_table, "LM Studio")
        self.tabs.addTab(self.lora_table, "Local LoRAs")
        self.tabs.currentChanged.connect(self._on_tab_changed)
        layout.addWidget(self.tabs)

        self._hf_total_size = 0
        self._lms_total_size = 0
        self._lora_total_size = 0
        self._lms_models_dir = resolve_lmstudio_models_dir()
        self.load_models()

    def _create_table(self, headers: list[str]) -> QTableWidget:
        table = QTableWidget(0, len(headers))
        table.setHorizontalHeaderLabels(headers)
        table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.verticalHeader().setVisible(False)
        table.setSortingEnabled(True)

        header_view = table.horizontalHeader()
        header_view.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        for col in range(1, len(headers) - 1):
            header_view.setSectionResizeMode(col, QHeaderView.ResizeMode.ResizeToContents)
        header_view.setSectionResizeMode(len(headers) - 1, QHeaderView.ResizeMode.ResizeToContents)
        table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        table.customContextMenuRequested.connect(
            lambda pos, t=table: self._show_row_context_menu(t, pos)
        )
        return table

    def _show_row_context_menu(self, table: QTableWidget, pos):
        row = table.rowAt(pos.y())
        if row < 0 or table.isRowHidden(row):
            return
        name_item = table.item(row, 0)
        if not name_item:
            return

        model_name = _full_name_from_item(name_item)
        folder = name_item.data(_FOLDER_ROLE)

        is_lms = table is self.lms_table
        is_lora = table is self.lora_table
        kind = ""
        if is_lms:
            type_item = table.item(row, 1)
            kind = type_item.text() if type_item else ""

        menu = QMenu(self)
        use_action = None
        if is_lms and kind == "LLM":
            use_action = menu.addAction("Use")
        copy_action = menu.addAction("Copy Path" if is_lora else "Copy Model Name")
        finder_action = menu.addAction("Open in Finder")
        finder_action.setEnabled(bool(folder))

        action = menu.exec(table.viewport().mapToGlobal(pos))
        if use_action and action == use_action:
            _use_llm_model(self, model_name)
        elif action == copy_action:
            from copy_feedback import copy_text_to_clipboard

            if is_lora:
                path_text = name_item.data(Qt.ItemDataRole.UserRole)
                copy_text = str(path_text or folder or model_name)
            else:
                copy_text = model_name
            copy_text_to_clipboard(copy_text, anchor=table.viewport())
        elif action == finder_action and folder:
            self._open_in_finder(folder)

    def _open_in_finder(self, folder: str):
        try:
            subprocess.run(["open", folder], check=True, timeout=5)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as exc:
            QMessageBox.warning(
                self,
                "Open in Finder",
                f"Could not open {folder} in Finder:\n{exc}",
            )

    def _on_format_toggled(self, checked: bool) -> None:
        self._strip_org_prefix = checked
        self._refresh_name_display()

    def _current_table(self) -> QTableWidget:
        idx = self.tabs.currentIndex()
        if idx == 0:
            return self.hf_table
        if idx == 1:
            return self.lms_table
        return self.lora_table

    def _refresh_name_display(self) -> None:
        for table in (self.hf_table, self.lms_table):
            for row in range(table.rowCount()):
                item = table.item(row, 0)
                if not item:
                    continue
                full_name = _full_name_from_item(item)
                item.setText(_display_model_name(full_name, self._strip_org_prefix))

    def _on_tab_changed(self, _index: int):
        self._apply_filter()
        self._update_status()

    def _row_matches_filter(self, table: QTableWidget, row: int, needle: str) -> bool:
        for col in range(table.columnCount() - 1):
            item = table.item(row, col)
            if not item:
                continue
            if needle in item.text().lower():
                return True
            full_name = item.data(_FULL_NAME_ROLE)
            if full_name and needle in str(full_name).lower():
                return True
            extra = item.data(Qt.ItemDataRole.UserRole)
            if extra and needle in str(extra).lower():
                return True
        return False

    def _apply_filter(self):
        table = self._current_table()
        needle = self.filter_edit.text().strip().lower()
        for row in range(table.rowCount()):
            if not needle:
                table.setRowHidden(row, False)
            else:
                table.setRowHidden(row, not self._row_matches_filter(table, row, needle))
        self._update_status()

    def _visible_row_count(self, table: QTableWidget) -> int:
        return sum(1 for row in range(table.rowCount()) if not table.isRowHidden(row))

    def _update_status(self):
        idx = self.tabs.currentIndex()
        if idx == 0:
            table = self.hf_table
            total = table.rowCount()
            visible = self._visible_row_count(table)
            total_size = _format_size(self._hf_total_size)
            if visible == total:
                self.status_label.setText(f"{total} cached repos, {total_size} total")
            else:
                self.status_label.setText(
                    f"{visible} of {total} cached repos shown, {total_size} total"
                )
        elif idx == 1:
            table = self.lms_table
            total = table.rowCount()
            visible = self._visible_row_count(table)
            total_size = _format_size(self._lms_total_size)
            if visible == total:
                self.status_label.setText(f"{total} LM Studio models, {total_size} total")
            else:
                self.status_label.setText(
                    f"{visible} of {total} LM Studio models shown, {total_size} total"
                )
        else:
            table = self.lora_table
            total = table.rowCount()
            visible = self._visible_row_count(table)
            total_size = _format_size(self._lora_total_size)
            if visible == total:
                self.status_label.setText(f"{total} local LoRA files, {total_size} total")
            else:
                self.status_label.setText(
                    f"{visible} of {total} local LoRA files shown, {total_size} total"
                )

    def load_models(self):
        self._load_hf_models()
        self._load_lmstudio_models()
        self._load_local_lora_models()
        self._apply_filter()

    def _load_hf_models(self):
        self.hf_table.setSortingEnabled(False)
        self.hf_table.setRowCount(0)

        cache_info = scan_cache_dir()
        repos = sorted(cache_info.repos, key=lambda r: r.repo_id.lower())
        self._hf_total_size = cache_info.size_on_disk

        self.hf_table.setRowCount(len(repos))
        for row, repo in enumerate(repos):
            full_name = repo.repo_id
            name_item = QTableWidgetItem(
                _display_model_name(full_name, self._strip_org_prefix)
            )
            name_item.setData(_FULL_NAME_ROLE, full_name)
            name_item.setData(Qt.ItemDataRole.UserRole, repo.repo_id)
            cache_dir = hf_repo_cache_dir(repo)
            if cache_dir:
                name_item.setData(_FOLDER_ROLE, str(cache_dir))

            type_item = QTableWidgetItem(infer_model_kind(repo))

            size_item = NumericSortItem(repo.size_on_disk_str, repo.size_on_disk)
            size_item.setTextAlignment(
                Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter
            )

            mtime = hf_repo_most_recent_mtime(repo)
            modified_item = NumericSortItem(_format_mtime(mtime), mtime)

            self.hf_table.setItem(row, 0, name_item)
            self.hf_table.setItem(row, 1, type_item)
            self.hf_table.setItem(row, 2, size_item)
            self.hf_table.setItem(row, 3, modified_item)

            delete_btn = _make_delete_button(
                lambda _checked=False, r=repo: self.confirm_delete_hf(r)
            )
            self.hf_table.setCellWidget(row, 4, delete_btn)

        self.hf_table.setSortingEnabled(True)

    def _load_lmstudio_models(self):
        self.lms_table.setSortingEnabled(False)
        self.lms_table.setRowCount(0)

        self._lms_models_dir = resolve_lmstudio_models_dir()
        models = scan_lmstudio_models()
        self._lms_total_size = sum(model.size_bytes for model in models)

        saved_key = _get_saved_lm_model_key()
        try:
            from gemma4_voice_vision_demo import _model_keys_match
        except Exception:
            _model_keys_match = None

        self.lms_table.setRowCount(len(models))
        for row, model in enumerate(models):
            rel_path = model.path.relative_to(self._lms_models_dir)
            full_name = model.model_id
            model_item = QTableWidgetItem(
                _display_model_name(full_name, self._strip_org_prefix)
            )
            model_item.setToolTip(str(rel_path))
            model_item.setData(_FULL_NAME_ROLE, full_name)
            model_item.setData(Qt.ItemDataRole.UserRole, f"{rel_path} {model.filename}")
            model_item.setData(_FOLDER_ROLE, str(model.path.parent))
            if (
                saved_key
                and _model_keys_match is not None
                and _model_keys_match(saved_key, full_name)
            ):
                bold_font = QFont(model_item.font())
                bold_font.setBold(True)
                model_item.setFont(bold_font)

            type_item = QTableWidgetItem(model.kind)
            format_item = QTableWidgetItem(model.format)
            quant_item = QTableWidgetItem(model.quant or "—")

            size_str = _format_size(model.size_bytes)
            size_item = NumericSortItem(size_str, model.size_bytes)
            size_item.setTextAlignment(
                Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter
            )

            modified_item = NumericSortItem(_format_mtime(model.mtime), model.mtime)

            self.lms_table.setItem(row, 0, model_item)
            self.lms_table.setItem(row, 1, type_item)
            self.lms_table.setItem(row, 2, format_item)
            self.lms_table.setItem(row, 3, quant_item)
            self.lms_table.setItem(row, 4, size_item)
            self.lms_table.setItem(row, 5, modified_item)

            delete_btn = _make_delete_button(
                lambda _checked=False, m=model: self.confirm_delete_lm(m)
            )
            self.lms_table.setCellWidget(row, 6, delete_btn)

        self.lms_table.setSortingEnabled(True)

    def _load_local_lora_models(self):
        from config import get_config

        self.lora_table.setSortingEnabled(False)
        self.lora_table.setRowCount(0)

        settings = get_config().load_settings()
        rows = scan_local_lora_rows(settings)
        self._lora_total_size = sum(row.size_bytes for row in rows)

        self.lora_table.setRowCount(len(rows))
        for row_idx, row in enumerate(rows):
            name_item = QTableWidgetItem(row.display_name)
            name_item.setData(_FULL_NAME_ROLE, row.display_name)
            name_item.setData(Qt.ItemDataRole.UserRole, str(row.path))
            if row.lora_id:
                name_item.setData(Qt.ItemDataRole.UserRole + 3, row.lora_id)
            name_item.setData(_FOLDER_ROLE, str(row.path.parent))

            visible_text = "✓" if row.unhidden else ""
            visible_item = NumericSortItem(visible_text, 1 if row.unhidden else 0)
            visible_item.setTextAlignment(
                Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignVCenter
            )

            size_item = NumericSortItem(_format_size(row.size_bytes), row.size_bytes)
            size_item.setTextAlignment(
                Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter
            )

            modified_item = NumericSortItem(_format_mtime(row.mtime), row.mtime)

            for item in (name_item, visible_item, size_item, modified_item):
                item.setToolTip(row.model_tooltip)

            self.lora_table.setItem(row_idx, 0, name_item)
            self.lora_table.setItem(row_idx, 1, visible_item)
            self.lora_table.setItem(row_idx, 2, size_item)
            self.lora_table.setItem(row_idx, 3, modified_item)

        self.lora_table.setSortingEnabled(True)

    def confirm_delete_hf(self, repo):
        reply = QMessageBox.question(
            self,
            "Delete Model",
            (
                f"Delete cached {repo.repo_type} '{repo.repo_id}'?\n\n"
                f"This will free {repo.size_on_disk_str}."
            ),
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if reply != QMessageBox.StandardButton.Yes:
            return

        revision_hashes = [rev.commit_hash for rev in repo.revisions]
        if not revision_hashes:
            QMessageBox.warning(
                self,
                "Delete Failed",
                f"No cached revisions found for '{repo.repo_id}'.",
            )
            return

        try:
            scan_cache_dir().delete_revisions(*revision_hashes).execute()
        except Exception as exc:
            QMessageBox.critical(
                self,
                "Delete Failed",
                f"Could not delete '{repo.repo_id}':\n{exc}",
            )
            return

        self.load_models()

    def confirm_delete_lm(self, model: LMStudioModel):
        size_str = _format_size(model.size_bytes)
        rel_path = model.path.relative_to(self._lms_models_dir)
        reply = QMessageBox.question(
            self,
            "Delete Model",
            (
                f"Delete LM Studio model file?\n\n"
                f"{rel_path}\n\n"
                f"This will free {size_str}."
            ),
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if reply != QMessageBox.StandardButton.Yes:
            return

        try:
            model.path.unlink()
            parent = model.path.parent
            while parent != self._lms_models_dir and parent.is_dir() and not any(parent.iterdir()):
                parent.rmdir()
                parent = parent.parent
        except Exception as exc:
            QMessageBox.critical(
                self,
                "Delete Failed",
                f"Could not delete '{rel_path}':\n{exc}",
            )
            return

        self.load_models()


_window: Optional[QWidget] = None


def _on_window_destroyed() -> None:
    global _window
    _window = None


def _use_llm_model(window: QWidget, model_id: str) -> None:
    """Load an LLM in LM Studio and persist it as the caption default."""
    model_id = model_id.strip()
    if not model_id:
        return

    progress = QProgressDialog(
        f"Loading {model_id} in LM Studio…",
        None,
        0,
        0,
        window,
    )
    progress.setWindowTitle("Use LLM")
    progress.setWindowModality(Qt.WindowModality.WindowModal)
    progress.setMinimumDuration(0)
    progress.setCancelButton(None)
    progress.show()

    class _LoadWorker(QThread):
        status = Signal(str)
        finished_ok = Signal(str)
        finished_err = Signal(str)

        def __init__(self, target_model_id: str):
            super().__init__()
            self._model_id = target_model_id

        def run(self):
            try:
                from config import get_config
                from gemma4_voice_vision_demo import (
                    ensure_lms_model_loaded,
                    resolve_lms_load_key,
                )

                load_key = resolve_lms_load_key(self._model_id)

                def emit_status(msg: str) -> None:
                    self.status.emit(msg)

                loaded_id = ensure_lms_model_loaded(
                    load_key,
                    status_cb=emit_status,
                )
                get_config().update_setting(
                    "caption_last_lm_model_key",
                    load_key,
                )
                self.finished_ok.emit(loaded_id or load_key)
            except Exception as exc:
                self.finished_err.emit(str(exc))

    def on_finished_ok(loaded_id: str) -> None:
        progress.close()
        if hasattr(window, "_load_lmstudio_models"):
            window._load_lmstudio_models()
            window._apply_filter()
        QMessageBox.information(
            window,
            "Use LLM",
            f"Loaded and set as default LLM:\n\n{loaded_id}\n\n(model: {model_id})",
        )

    def on_finished_err(err: str) -> None:
        progress.close()
        QMessageBox.warning(
            window,
            "Use LLM",
            f"Could not load {model_id!r}:\n\n{err}",
        )

    worker = _LoadWorker(model_id)
    worker.status.connect(progress.setLabelText)
    worker.finished_ok.connect(on_finished_ok)
    worker.finished_err.connect(on_finished_err)
    worker.finished.connect(worker.deleteLater)
    worker.start()
    window._use_llm_worker = worker


def run_list_models_window(parent: Optional[QWidget] = None) -> QWidget:
    """Open (or raise) the cached models browser."""
    global _window

    if _window is not None:
        try:
            if _window.isVisible():
                raise_dialog_without_space_hop(_window)
                return _window
        except RuntimeError:
            _window = None

    window = ListModelsWindow(parent)
    configure_filter_clear_button(window)
    window.setAttribute(Qt.WA_DeleteOnClose, True)
    window.destroyed.connect(_on_window_destroyed)
    _window = window
    present_auxiliary_dialog(window)
    return window
