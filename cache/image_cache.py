#!/usr/bin/env python3
"""
Image Cache System
Provides multiple layers of caching for thumbnails, metadata, and full images
"""

# Standard library imports
import hashlib
import heapq
import json
import os
from dataclasses import dataclass
from datetime import datetime
import traceback
from typing import Dict, List, NamedTuple, Optional, Set, Tuple, Callable
import time # Added for time.time()
import inspect

# Third-party imports
from PySide6.QtCore import QMutex, QMutexLocker, QObject, Qt, QReadWriteLock, QThread, Signal, QTimer, QMetaObject, QWaitCondition
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import QApplication

# Local imports
from config import get_config
from thumbnails.thumbnail_constants import RED, RESET, GREEN, YELLOW, BLUE, MAGENTA, CYAN, WHITE, THUMBNAIL_GENERATION_THREADS
from cache.thumbnail_cache_key import compute_thumbnail_cache_key, is_path_in_app_cache_directory
from utils import _usleep_ms, _usleep_ms_interruptible


class ImageMetadata(NamedTuple):
    """Image metadata structure"""
    filename: str
    file_size: int
    modified_time: float
    source_directory: str  # Add source directory tracking
    width: int = 0  # Image width after EXIF correction
    height: int = 0  # Image height after EXIF correction
    exif_taken_time: Optional[float] = None  # EXIF DateTimeOriginal/DateTimeDigitized timestamp, or None if not available
    
class CachedThumbnail(NamedTuple):
    """Cached thumbnail structure"""
    pixmap: QPixmap
    size: int  # thumbnail size it was generated for
    created_time: float


class ThumbnailDirSnapshot(NamedTuple):
    """Immutable snapshot of disk thumbnail index for worker threads."""
    filenames: frozenset
    prefix_index: Dict[str, Tuple[Tuple[int, str], ...]]


@dataclass
class CacheStats:
    """Cache statistics"""
    thumbnail_hits: int = 0
    thumbnail_misses: int = 0
    metadata_hits: int = 0
    metadata_misses: int = 0
    fullimage_hits: int = 0
    fullimage_misses: int = 0
    
    def hit_rate(self, cache_type: str) -> float:
        """Calculate hit rate for a cache type"""
        if cache_type == 'thumbnail':
            total = self.thumbnail_hits + self.thumbnail_misses
            return self.thumbnail_hits / total if total > 0 else 0.0
        elif cache_type == 'metadata':
            total = self.metadata_hits + self.metadata_misses
            return self.metadata_hits / total if total > 0 else 0.0
        elif cache_type == 'fullimage':
            total = self.fullimage_hits + self.fullimage_misses
            return self.fullimage_hits / total if total > 0 else 0.0
        return 0.0

class ThumbnailWorkerThread(QThread):
    """Individual worker thread for processing thumbnail requests"""
    
    thumbnail_loaded = Signal(str, QPixmap, int)  # path, pixmap, size
    metadata_loaded = Signal(str, object)  # path, ImageMetadata
    fullimage_loaded = Signal(str, QPixmap)  # path, pixmap
    error_occurred = Signal(str, str)  # path, error_message
    
    def __init__(self, cache_manager, background_loader, queue_mutex, queue_wait_condition, should_stop_flag, thread_id=0, parent=None):
        super().__init__(parent)
        self.cache_manager = cache_manager
        self.background_loader = background_loader  # Store reference to parent to access queue
        self.queue_mutex = queue_mutex
        self.queue_wait_condition = queue_wait_condition
        self.should_stop_flag = should_stop_flag
        self.thread_id = thread_id  # Store thread ID for staggered sleep times
    
    @property
    def load_queue(self):
        """Access queue through parent to ensure we always get the current queue"""
        return self.background_loader.load_queue
    
    def run(self):
        """Main worker thread loop"""
        from thumbnails.thumbnail_constants import THUMBNAIL_WORKER_BATCH_SIZE, THUMBNAIL_WORKER_BATCH_PAUSE_MS
        import time

        process_count = 0
        batch_size = THUMBNAIL_WORKER_BATCH_SIZE
        batch_pause_seconds = THUMBNAIL_WORKER_BATCH_PAUSE_MS / 1000.0  # Convert ms to seconds
        
        # Calculate staggered sleep time to prevent thundering herd GIL contention
        # Spread threads over ~100ms to avoid simultaneous wake-up
        base_sleep = 0.1  # 100ms base sleep
        stagger_offset = (self.thread_id * 0.008)  # ~8ms per thread (spreads 12 threads over ~96ms)
        staggered_sleep = base_sleep + stagger_offset
        idle_backoff_level = 0
        max_idle_backoff_level = 3  # Cap idle delay to keep request pickup responsive
        max_idle_sleep = 0.25  # 250ms max idle delay to avoid noticeable UI lag
        
        while not self.should_stop_flag[0]:
            request = None
            # Get next request from queue
            with QMutexLocker(self.queue_mutex):
                if self.load_queue and not self.should_stop_flag[0]:
                    _, _, request = heapq.heappop(self.load_queue)
                    if len(request) >= 3 and request[0] == 'thumbnail':
                        self.background_loader._queued_thumbnails.pop(
                            (request[1], request[2]), None
                        )
            
            if not request:
                # No requests available - use time.sleep() instead of msleep() or QWaitCondition.wait()
                # QWaitCondition.wait() requires GIL acquisition when returning (PyEval_RestoreThread),
                # which causes deadlock when main thread holds GIL doing blocking operations.
                # QThread.msleep() ALSO requires GIL restoration (PyEval_RestoreThread) when returning,
                # which causes deadlock. 
                # CRITICAL: nanosleep via ctypes ALSO causes deadlock because ctypes.callproc requires
                # GIL acquisition when returning from the C function, even though nanosleep itself doesn't
                # need the GIL. This creates a deadlock when main thread is dropping GIL during signal
                # connections (e.g., QTimer.singleShot).
                # time.sleep() properly releases the GIL during sleep and handles GIL acquisition correctly
                # when returning, preventing deadlock.
                # CRITICAL FIX: Use staggered sleep times to prevent thundering herd GIL contention.
                # When multiple threads wake up simultaneously, they all try to acquire the GIL at once,
                # causing deadlock when main thread is dropping GIL during Qt signal connections.
                if self.should_stop_flag[0]:
                    return
                # Sleep with thread-specific offset to stagger wake-up times and reduce GIL contention.
                # Add adaptive backoff so idle workers wake less frequently but remain responsive.
                idle_backoff_level = min(idle_backoff_level + 1, max_idle_backoff_level)
                idle_sleep = min(staggered_sleep * (2 ** idle_backoff_level), max_idle_sleep)
                _usleep_ms_interruptible(
                    idle_sleep * 1000,
                    should_stop=lambda: self.should_stop_flag[0],
                )
                if self.should_stop_flag[0]:
                    return
                continue
            
            # Reset idle backoff after successful dequeue
            idle_backoff_level = 0
            process_count += 1
            
            # Check should_stop before processing
            if self.should_stop_flag[0]:
                break
            
            try:
                request_type = request[0]
                image_path = request[1]
                size_or_none = request[2]
                priority = request[3]
                
                if request_type == 'thumbnail':
                    size = size_or_none
                    if self.should_stop_flag[0]:
                        break
                    pixmap = self._load_thumbnail_sync(image_path, size)
                    if self.should_stop_flag[0]:
                        break
                    if pixmap and not pixmap.isNull():
                        self.thumbnail_loaded.emit(image_path, pixmap, size)
                        
                elif request_type == 'metadata':
                    if self.should_stop_flag[0]:
                        break
                    metadata = self._load_metadata_sync(image_path)
                    if self.should_stop_flag[0]:
                        break
                    if metadata:
                        self.metadata_loaded.emit(image_path, metadata)
                        
                elif request_type == 'fullimage':
                    if self.should_stop_flag[0]:
                        break
                    pixmap = self.load_fullimage_sync(image_path)
                    if self.should_stop_flag[0]:
                        break
                    if pixmap and not pixmap.isNull():
                        self.fullimage_loaded.emit(image_path, pixmap)
                        
            except Exception as e:
                if not self.should_stop_flag[0]:
                    self.error_occurred.emit(image_path, str(e))
            
            # Pause between batches to reduce CPU contention and allow main thread to process events
            if process_count % batch_size == 0:
                self.cache_manager.schedule_flush_thumbnail_dir_index()
                if batch_pause_seconds > 0:
                    _usleep_ms_interruptible(
                        batch_pause_seconds * 1000,
                        should_stop=lambda: self.should_stop_flag[0],
                    )
                    if self.should_stop_flag[0]:
                        return
                # Reset counter periodically to avoid overflow
                if process_count > 32000:
                    process_count = 0
    
    def _return_noimage_cached(self, image_path: str, size: int):
        """Load noimage placeholder and persist to disk so failures are not retried forever."""
        from exif.exif_image_loader import load_noimage_thumbnail

        pixmap = load_noimage_thumbnail(size)
        if pixmap and not pixmap.isNull():
            self.cache_manager.cache_thumbnail_sync(
                image_path, pixmap, size, defer_index_update=True
            )
        return pixmap

    def _load_thumbnail_sync(self, image_path: str, size: int) -> Optional[QPixmap]:
        """Load thumbnail synchronously with EXIF correction"""
        try:
            if self.should_stop_flag[0]:
                return None
                
            # Check cache first
            snapshot = self.cache_manager.get_thumbnail_dir_snapshot()
            listing = snapshot.filenames if snapshot else None
            cached = self.cache_manager.get_thumbnail_sync(
                image_path, size, thumbnail_dir_listing=listing
            )
            if cached:
                # print(f"Thumbnail cache hit for {image_path} at size {size}")
                return cached
            
            # print(f"Thumbnail cache miss for {image_path} at size {size}")
            if self.should_stop_flag[0]:
                return None
            
            # Load and create thumbnail with EXIF correction
            try:
                from exif.exif_image_loader import load_thumbnail_with_exif_correction
                # Use cached ignore_exif_rotation setting instead of loading config every time
                ignore_exif = self.cache_manager.get_ignore_exif_setting()
                loader_result = load_thumbnail_with_exif_correction(
                    image_path, size, ignore_exif=ignore_exif, return_metadata=True
                )
                pixmap = None
                loader_meta = None
                if loader_result:
                    if isinstance(loader_result, tuple):
                        pixmap, loader_meta = loader_result[0], loader_result[1:]
                    else:
                        pixmap = loader_result
                if self.should_stop_flag[0]:
                    return None
                if pixmap and not pixmap.isNull():
                    self.cache_manager.cache_thumbnail_sync(
                        image_path, pixmap, size,
                        loader_metadata=loader_meta,
                        defer_index_update=True,
                    )
                    return pixmap
                return self._return_noimage_cached(image_path, size)
            except ImportError:
                if self.should_stop_flag[0]:
                    return None
                pixmap = QPixmap(image_path)
                if self.should_stop_flag[0]:
                    return None
                if not pixmap.isNull():
                    scaled_pixmap = pixmap.scaled(
                        size, size,
                        Qt.KeepAspectRatio,
                        Qt.SmoothTransformation
                    )
                    if self.should_stop_flag[0]:
                        return None
                    # Cache it (will skip if in app cache directory)
                    self.cache_manager.cache_thumbnail_sync(
                        image_path, scaled_pixmap, size, defer_index_update=True
                    )
                    return scaled_pixmap
                return self._return_noimage_cached(image_path, size)

        except Exception as e:
            pass # print(f"Error loading thumbnail for {image_path}: {e}")
        return self._return_noimage_cached(image_path, size)
    
    def _load_metadata_sync(self, image_path: str) -> Optional[ImageMetadata]:
        """Load metadata synchronously with EXIF correction"""
        try:
            # Check cache first
            cached = self.cache_manager.get_metadata_sync(image_path)
            if cached:
                # Ensure cached metadata has source directory
                if hasattr(cached, 'source_directory') and cached.source_directory and cached.source_directory != "Unknown":
                    return cached
                # If cached metadata exists but has no valid source directory, reload it
            
            # Load metadata
            if not os.path.exists(image_path):
                # Don't cache metadata for non-existent files
                return None
                
            stat = os.stat(image_path)
            
            # Always capture the absolute source directory - this is critical for cache consistency
            source_dir = os.path.dirname(os.path.abspath(image_path))
            
            # Get dimensions and EXIF date/time quickly using fast metadata method
            dimensions = None
            exif_taken_time = None
            try:
                from exif.exif_image_loader import get_image_dimensions_and_exif_date
                result = get_image_dimensions_and_exif_date(image_path)
                if result:
                    dimensions, exif_taken_time = result
            except ImportError:
                # Fallback to dimensions-only if new function not available
                try:
                    from exif.exif_image_loader import get_image_dimensions_fast_metadata
                    dimensions = get_image_dimensions_fast_metadata(image_path)
                except ImportError:
                    pass
            
            # Create metadata with all required fields including dimensions and EXIF date/time
            metadata = ImageMetadata(
                filename=os.path.basename(image_path),
                file_size=stat.st_size,
                modified_time=stat.st_mtime,
                source_directory=source_dir,  # Always set the actual source directory
                width=dimensions[0] if dimensions else 0,
                height=dimensions[1] if dimensions else 0,
                exif_taken_time=exif_taken_time  # EXIF date/time timestamp, or None if not available
            )
            
            # Cache it immediately (will skip if in app cache directory)
            self.cache_manager.cache_metadata_sync(image_path, metadata)
            return metadata
                
        except Exception as e:
            pass # print(f"Error loading metadata for {image_path}: {e}")
        return None
    
    def load_fullimage_sync(self, image_path: str) -> Optional[QPixmap]:
        """Load full image synchronously with EXIF correction"""
        try:
            # Check cache first
            cached = self.cache_manager.get_fullimage_sync(image_path)
            if cached:
                return cached
            
            # Load full image with EXIF correction
            try:
                from exif.exif_image_loader import load_image_with_exif_correction
                # Use cached ignore_exif_rotation setting instead of loading config every time
                ignore_exif = self.cache_manager.get_ignore_exif_setting()
                pixmap = load_image_with_exif_correction(image_path, ignore_exif=ignore_exif)
                if pixmap and not pixmap.isNull():
                    pass # print(f"Full image sync EXIF-corrected load for {os.path.basename(image_path)}: size={pixmap.size()}")
                    # Cache it if not too large (limit to reasonable memory usage)
                    # Will skip if in app cache directory
                    if pixmap.width() * pixmap.height() < 8000000:  # ~8MP limit
                        self.cache_manager.cache_fullimage_sync(image_path, pixmap)
                    return pixmap
            except ImportError:
                # Fallback to direct QPixmap loading if exif_image_loader not available
                pixmap = QPixmap(image_path)
                if not pixmap.isNull():
                    pass # print(f"Full image sync direct load for {os.path.basename(image_path)}: size={pixmap.size()}")
                    # Cache it if not too large (limit to reasonable memory usage)
                    # Will skip if in app cache directory
                    if pixmap.width() * pixmap.height() < 8000000:  # ~8MP limit
                        self.cache_manager.cache_fullimage_sync(image_path, pixmap)
                    return pixmap
                
        except Exception as e:
            pass # print(f"Error loading full image {image_path}: {e}")
        return None


class BackgroundImageLoader(QObject):
    """Manages multiple background threads for loading images without blocking UI"""
    
    # Signals (forwarded from worker threads)
    thumbnail_loaded = Signal(str, QPixmap, int)  # path, pixmap, size
    metadata_loaded = Signal(str, object)  # path, ImageMetadata
    fullimage_loaded = Signal(str, QPixmap)  # path, pixmap
    error_occurred = Signal(str, str)  # path, error_message
    
    def __init__(self, cache_manager):
        super().__init__()
        self.cache_manager = cache_manager
        self.load_queue: List[Tuple[int, int, tuple]] = []
        self.queue_mutex = QMutex()
        self.queue_wait_condition = QWaitCondition()  # Wake workers when work arrives
        self.should_stop = [False]  # Use list to allow sharing between threads
        self.request_sequence = 0
        self.worker_threads = []
        self.num_threads = THUMBNAIL_GENERATION_THREADS
        self._queued_thumbnails: Dict[Tuple[str, int], int] = {}  # (path, size) -> priority
        
    def add_thumbnail_request(self, image_path: str, size: int, priority: int = 0):
        """Add thumbnail loading request"""
        queue_key = (image_path, size)
        with QMutexLocker(self.queue_mutex):
            existing_priority = self._queued_thumbnails.get(queue_key)
            if existing_priority is not None and priority <= existing_priority:
                return
            if existing_priority is not None:
                self.load_queue[:] = [
                    item for item in self.load_queue
                    if not (
                        len(item) >= 3
                        and len(item[2]) >= 5
                        and item[2][0] == 'thumbnail'
                        and item[2][1] == image_path
                        and item[2][2] == size
                    )
                ]
                heapq.heapify(self.load_queue)
            self._queued_thumbnails[queue_key] = priority
            self.request_sequence += 1
            request = ('thumbnail', image_path, size, priority, self.request_sequence)
            heapq.heappush(self.load_queue, (-priority, self.request_sequence, request))
            self.queue_wait_condition.wakeOne()
    
    def remove_requests_for_file(self, image_path: str):
        """Remove all requests for a specific file from the queue"""
        with QMutexLocker(self.queue_mutex):
            self.load_queue[:] = [
                item for item in self.load_queue
                if not (len(item) >= 3 and len(item[2]) >= 2 and item[2][1] == image_path)
            ]
            heapq.heapify(self.load_queue)
            self._queued_thumbnails = {
                k: v for k, v in self._queued_thumbnails.items() if k[0] != image_path
            }

    def clear_queued_thumbnail_requests(
        self,
        *,
        paths: Optional[Set[str]] = None,
        size: Optional[int] = None,
        max_priority: Optional[int] = None,
        all_requests: bool = False,
    ) -> None:
        """Drop pending thumbnail requests and keep _queued_thumbnails in sync."""
        with QMutexLocker(self.queue_mutex):
            if all_requests:
                self.load_queue.clear()
                self._queued_thumbnails.clear()
                return

            def _matches(item) -> bool:
                if len(item) < 3 or len(item[2]) < 5 or item[2][0] != 'thumbnail':
                    return False
                path = item[2][1]
                thumb_size = item[2][2]
                priority = item[2][3]
                if paths is not None and path not in paths:
                    return False
                if size is not None and thumb_size != size:
                    return False
                if max_priority is not None and priority > max_priority:
                    return False
                return True

            removed_keys: Set[Tuple[str, int]] = set()
            kept_queue = []
            for item in self.load_queue:
                if _matches(item):
                    removed_keys.add((item[2][1], item[2][2]))
                else:
                    kept_queue.append(item)
            self.load_queue = kept_queue
            heapq.heapify(self.load_queue)
            for key in removed_keys:
                self._queued_thumbnails.pop(key, None)
    
    def start(self):
        """Start all worker threads"""
        self.worker_threads = [w for w in self.worker_threads if w.isRunning()]
        while len(self.worker_threads) < self.num_threads:
            thread_id = len(self.worker_threads)
            worker = ThumbnailWorkerThread(
                self.cache_manager,
                self,  # Pass self so worker can access queue through us
                self.queue_mutex,
                self.queue_wait_condition,
                self.should_stop,
                thread_id=thread_id,  # Pass thread index for staggered sleep times
                parent=self
            )
            # Connect worker signals to our signals with QueuedConnection for thread safety
            worker.thumbnail_loaded.connect(self.thumbnail_loaded, Qt.QueuedConnection)
            worker.metadata_loaded.connect(self.metadata_loaded, Qt.QueuedConnection)
            worker.fullimage_loaded.connect(self.fullimage_loaded, Qt.QueuedConnection)
            worker.error_occurred.connect(self.error_occurred, Qt.QueuedConnection)
            
            worker.start()
            self.worker_threads.append(worker)
    
    def isRunning(self):
        """Check if any worker threads are running"""
        return any(worker.isRunning() for worker in self.worker_threads)
    
    def stop(self):
        """Stop all background threads"""
        fast_quit = os.environ.get("PROWSER_QUIT_AFTER_STARTUP", "").strip().lower() in (
            "1",
            "true",
            "yes",
        )
        # Set stop flag first so threads can check it and exit gracefully
        self.should_stop[0] = True
        
        # Wake all waiting threads so they can check should_stop and exit
        self.queue_wait_condition.wakeAll()
        
        # Clear the queue with mutex protection to prevent threads from getting new work
        # This allows threads to finish current work and exit naturally
        try:
            with QMutexLocker(self.queue_mutex):
                self.load_queue.clear()
                self._queued_thumbnails.clear()
        except Exception:
            # If mutex is locked by a thread, that's OK - threads will check should_stop flag
            pass
        
        # Wait for threads to exit gracefully (with timeout)
        import time
        start_time = time.time()
        timeout = 0.1 if fast_quit else 0.25  # shorter wait for startup profiling quit
        
        # Store reference to threads
        old_threads = list(self.worker_threads)
        self.worker_threads.clear()
        
        # Wait for threads to exit
        while time.time() - start_time < timeout:
            all_stopped = True
            for worker in old_threads:
                try:
                    if worker.isRunning():
                        all_stopped = False
                        break
                except Exception:
                    pass
            
            if all_stopped:
                break
            
            # Small sleep to avoid busy-waiting
            time.sleep(0.01)
        
        # If threads are still running after timeout, terminate them
        # This is necessary for clean shutdown
        for worker in old_threads:
            try:
                if worker.isRunning():
                    worker.requestInterruption()
                    worker.terminate()
                    worker.wait(50 if fast_quit else 300)
            except Exception:
                pass

        # Cleanup thread objects - only deleteLater if thread has stopped (avoids Qt abort)
        for worker in old_threads:
            try:
                if not worker.isRunning():
                    worker.deleteLater()
            except Exception:
                pass
        
        # Reset stop flag only when workers have actually stopped (avoid zombie loops)
        if not any(worker.isRunning() for worker in old_threads):
            self.should_stop[0] = False

class ImageCacheManager(QObject):
    """
    Comprehensive image cache manager with multiple cache layers:
    1. In-memory LRU caches for thumbnails, metadata, and full images
    2. Persistent disk cache for thumbnails
    3. Background loading with prioritization
    """
    
    # Signals
    thumbnail_ready = Signal(str, QPixmap, int)  # path, pixmap, size
    metadata_ready = Signal(str, object)  # path, ImageMetadata
    fullimage_ready = Signal(str, QPixmap)  # path, pixmap

    def __init__(self, cache_dir: Optional[str] = None, 
                 max_thumbnail_cache: int = 12000,
                 max_metadata_cache: int = 12000,
                 max_fullimage_cache: int = 15,
                 start_background_loader: bool = True):
        super().__init__()
        
        # Cache directory setup
        if cache_dir is None:
            config = get_config()
            self.cache_dir = str(config.image_cache_dir)
            self.thumbnail_cache_dir = str(config.thumbnail_cache_dir)
            self.metadata_cache_file = os.path.join(str(config.metadata_cache_dir), "metadata_cache.json")
        else:
            self.cache_dir = cache_dir
            self.thumbnail_cache_dir = os.path.join(cache_dir, "thumbnails")
            self.metadata_cache_file = os.path.join(cache_dir, "metadata_cache.json")
        
        # Ensure cache directories exist
        os.makedirs(self.cache_dir, exist_ok=True)
        os.makedirs(self.thumbnail_cache_dir, exist_ok=True)
        
        # Cache limits
        self.max_thumbnail_cache = max_thumbnail_cache
        self.max_metadata_cache = max_metadata_cache
        self.max_fullimage_cache = max_fullimage_cache
        
        # In-memory caches
        self.thumbnail_cache = {}  # cache_key -> CachedThumbnail
        self._thumbnail_key_index: Dict[str, Set[str]] = {}  # cache_key_base -> set of full keys (avoids O(N) scan on clear)
        self.metadata_cache = {}   # cache_key -> ImageMetadata
        self.fullimage_cache = {}  # cache_key -> QPixmap
        
        # Source directory tracking
        self.source_directories = set()
        
        # Thread safety
        self.cache_mutex = QMutex()
        self._metadata_changed_notifier: Optional[Callable[[str, Optional[Set[str]]], None]] = None
        
        # Store ignore_exif_rotation setting to avoid reading from file every time
        # This prevents timing issues when settings are being saved
        self._ignore_exif_rotation = None  # None means not initialized, will read from config
        self._update_ignore_exif_setting()
        
        # Cache for stat results to avoid repeated os.stat() calls (especially important for network volumes)
        # Maps image_path -> (mtime, cache_time) where cache_time is when we cached it
        self._stat_cache = {}
        self._stat_cache_max_age = 60.0  # Cache stat results for 60 seconds (longer for rename operations)
        self._stat_cache_mutex = QMutex()
        
        # Statistics
        self.stats = CacheStats()
        
        # LRU counter for efficient cache management (replaces expensive timestamps)
        self._lru_counter = 0
        
        # Initialize cache structures (needed before _refresh_thumbnail_dir_cache)
        self._thumbnail_dir_cache = set()
        self._thumbnail_dir_cache_time = 0
        self._thumbnail_dir_cache_valid = False
        self._thumbnail_prefix_index: Dict[str, List[Tuple[int, str]]] = {}
        self._pending_index_adds: Set[str] = set()
        self._pending_index_removes: Set[str] = set()
        self._pending_index_mutex = QMutex()
        self._dir_index_flush_timer: Optional[QTimer] = None
        self._dir_snapshot_lock = QReadWriteLock()
        self._thumbnail_dir_snapshot: Optional[ThumbnailDirSnapshot] = None
        self._metadata_validation_times: Dict[str, float] = {}
        self._metadata_dirty = False
        self._dir_cache_full_refresh_count = 0
        self._dir_cache_incremental_update_count = 0
        self._metadata_stat_on_hit_count = 0
        
        # Background loader (skip for headless/worker processes to avoid QThread shutdown crash)
        if start_background_loader:
            self.background_loader = BackgroundImageLoader(self)
            # Connect with QueuedConnection for thread safety - forward directly to external listeners
            self.background_loader.thumbnail_loaded.connect(self.thumbnail_ready, Qt.QueuedConnection)
            self.background_loader.metadata_loaded.connect(self.metadata_ready, Qt.QueuedConnection)
            self.background_loader.fullimage_loaded.connect(self.fullimage_ready, Qt.QueuedConnection)
            self.background_loader.error_occurred.connect(self._on_error_occurred, Qt.QueuedConnection)
            self.background_loader.start()
            # Defer blocking cache operations to avoid beachball on startup (especially for network volumes)
            QTimer.singleShot(0, self._load_metadata_cache)
            QTimer.singleShot(0, self._refresh_thumbnail_dir_cache)
        else:
            self.background_loader = None
            self._refresh_thumbnail_dir_cache()
        
        # Periodic cache saving
        self._last_save_time = time.time()
        self._save_interval = 30.0  # Save every 30 seconds
        self._save_timer = QTimer()
        self._save_timer.timeout.connect(self._periodic_save)
        self._save_timer.start(10000)  # Check every 10 seconds
        
        # Store app cache directory path for exclusion check
        config = get_config()
        self._app_cache_dir = str(config.cache_dir)
    
    def is_in_app_cache_directory(self, image_path: str) -> bool:
        """Check if an image path is within the application's cache directory
        
        Args:
            image_path: Path to check
            
        Returns:
            True if the path is within the app's cache directory, False otherwise
        """
        return is_path_in_app_cache_directory(image_path, self._app_cache_dir)
    
    def _refresh_thumbnail_dir_cache(self):
        """Refresh the cached thumbnail directory listing and prefix index."""
        try:
            if os.path.exists(self.thumbnail_cache_dir):
                filenames = os.listdir(self.thumbnail_cache_dir)
                self._thumbnail_dir_cache = set(filenames)
                prefix_index: Dict[str, List[Tuple[int, str]]] = {}
                for filename in filenames:
                    parsed = self._parse_thumbnail_cache_filename(filename)
                    if not parsed:
                        continue
                    prefix, cached_size = parsed
                    prefix_index.setdefault(prefix, []).append((cached_size, filename))
                self._thumbnail_prefix_index = prefix_index
                self._thumbnail_dir_cache_time = time.time()
                self._thumbnail_dir_cache_valid = True
                self._dir_cache_full_refresh_count += 1
                self._publish_dir_snapshot()
            else:
                self._thumbnail_dir_cache = set()
                self._thumbnail_prefix_index = {}
                self._thumbnail_dir_cache_valid = False
                self._publish_dir_snapshot()
        except Exception:
            self._thumbnail_dir_cache = set()
            self._thumbnail_prefix_index = {}
            self._thumbnail_dir_cache_valid = False
            self._publish_dir_snapshot()

    @staticmethod
    def _parse_thumbnail_cache_filename(filename: str) -> Optional[Tuple[str, int]]:
        if not filename.endswith('.jpg'):
            return None
        stem = filename[:-4]
        if '_' not in stem:
            return None
        prefix, size_part = stem.rsplit('_', 1)
        try:
            return prefix, int(size_part)
        except ValueError:
            return None

    def _publish_dir_snapshot(self):
        prefix_snapshot = {
            prefix: tuple(variants)
            for prefix, variants in self._thumbnail_prefix_index.items()
        }
        snapshot = ThumbnailDirSnapshot(
            filenames=frozenset(self._thumbnail_dir_cache),
            prefix_index=prefix_snapshot,
        )
        self._dir_snapshot_lock.lockForWrite()
        try:
            self._thumbnail_dir_snapshot = snapshot
        finally:
            self._dir_snapshot_lock.unlock()

    def get_thumbnail_dir_snapshot(self) -> Optional[ThumbnailDirSnapshot]:
        self._dir_snapshot_lock.lockForRead()
        try:
            return self._thumbnail_dir_snapshot
        finally:
            self._dir_snapshot_lock.unlock()

    def _apply_index_add(self, filename: str):
        parsed = self._parse_thumbnail_cache_filename(filename)
        if not parsed:
            return
        prefix, cached_size = parsed
        self._thumbnail_dir_cache.add(filename)
        variants = self._thumbnail_prefix_index.setdefault(prefix, [])
        variants[:] = [(s, f) for s, f in variants if s != cached_size]
        variants.append((cached_size, filename))
        self._thumbnail_dir_cache_time = time.time()
        self._thumbnail_dir_cache_valid = True
        self._dir_cache_incremental_update_count += 1

    def _apply_index_remove(self, filename: str):
        self._thumbnail_dir_cache.discard(filename)
        parsed = self._parse_thumbnail_cache_filename(filename)
        if parsed:
            prefix, _cached_size = parsed
            variants = self._thumbnail_prefix_index.get(prefix)
            if variants:
                new_variants = [(s, f) for s, f in variants if f != filename]
                if new_variants:
                    self._thumbnail_prefix_index[prefix] = new_variants
                else:
                    del self._thumbnail_prefix_index[prefix]
        self._dir_cache_incremental_update_count += 1

    def _is_main_thread(self) -> bool:
        try:
            app = QApplication.instance()
            if app:
                return QThread.currentThread() == app.thread()
        except Exception:
            pass
        return True

    def schedule_flush_thumbnail_dir_index(self) -> None:
        """Coalesce deferred index updates onto the main thread."""
        if not self._is_main_thread():
            QTimer.singleShot(0, self._flush_thumbnail_dir_index_on_main)
            return
        timer = self._dir_index_flush_timer
        if timer is None:
            timer = QTimer(self)
            timer.setSingleShot(True)
            timer.timeout.connect(self._flush_thumbnail_dir_index_on_main)
            self._dir_index_flush_timer = timer
        if not timer.isActive():
            timer.start(0)

    def _flush_thumbnail_dir_index_on_main(self) -> None:
        if not self._is_main_thread():
            QTimer.singleShot(0, self._flush_thumbnail_dir_index_on_main)
            return
        self.flush_thumbnail_dir_index()

    def _queue_index_add(self, filename: str, defer: bool = False):
        if defer:
            with QMutexLocker(self._pending_index_mutex):
                self._pending_index_adds.add(filename)
                self._pending_index_removes.discard(filename)
            return
        self._apply_index_add(filename)
        self._publish_dir_snapshot()

    def _queue_index_remove(self, filename: str, defer: bool = False):
        if defer:
            with QMutexLocker(self._pending_index_mutex):
                self._pending_index_removes.add(filename)
                self._pending_index_adds.discard(filename)
            return
        self._apply_index_remove(filename)
        self._publish_dir_snapshot()

    def flush_thumbnail_dir_index(self):
        """Apply deferred thumbnail directory index updates (main thread only)."""
        if not self._is_main_thread():
            self.schedule_flush_thumbnail_dir_index()
            return
        with QMutexLocker(self._pending_index_mutex):
            if not self._pending_index_adds and not self._pending_index_removes:
                return
            removes = self._pending_index_removes
            adds = self._pending_index_adds
            self._pending_index_removes = set()
            self._pending_index_adds = set()
        for filename in removes:
            self._apply_index_remove(filename)
        for filename in adds:
            if filename not in removes:
                self._apply_index_add(filename)
        self._publish_dir_snapshot()

    def _thumbnail_cached_in_snapshot(
        self,
        snapshot: ThumbnailDirSnapshot,
        cache_key_base: str,
        size: int,
        exact_filename: str,
    ) -> bool:
        if exact_filename in snapshot.filenames:
            return True
        indexed_variants = snapshot.prefix_index.get(cache_key_base)
        if indexed_variants:
            return any(cached_size >= size for cached_size, _ in indexed_variants)
        return False

    def _thumbnail_cached_in_pending(
        self, cache_key_base: str, size: int, exact_filename: str
    ) -> bool:
        with QMutexLocker(self._pending_index_mutex):
            pending_adds = set(self._pending_index_adds)
            pending_removes = set(self._pending_index_removes)
        if exact_filename in pending_removes:
            return False
        if exact_filename in pending_adds:
            return True
        for filename in pending_adds:
            parsed = self._parse_thumbnail_cache_filename(filename)
            if parsed and parsed[0] == cache_key_base and parsed[1] >= size:
                return True
        return False

    def is_thumbnail_cached_on_disk(self, image_path: str, size: int) -> bool:
        """Fast disk-cache presence check using the published prefix snapshot."""
        if self._is_main_thread() and not self._thumbnail_dir_cache_valid:
            self._refresh_thumbnail_dir_cache()
        cache_key_base = self.get_cache_key(image_path)
        exact_filename = f"{cache_key_base}_{size}.jpg"
        snapshot = self.get_thumbnail_dir_snapshot()
        if snapshot is not None and self._thumbnail_dir_cache_valid:
            if self._thumbnail_cached_in_snapshot(
                snapshot, cache_key_base, size, exact_filename
            ):
                return True
            if self._is_main_thread():
                return self._thumbnail_cached_in_pending(
                    cache_key_base, size, exact_filename
                )
            return False
        if not self._is_main_thread():
            return False
        if self._thumbnail_dir_cache_valid and exact_filename in self._thumbnail_dir_cache:
            return True
        indexed_variants = self._thumbnail_prefix_index.get(cache_key_base) if self._thumbnail_dir_cache_valid else None
        if indexed_variants:
            return any(cached_size >= size for cached_size, _ in indexed_variants)
        return self._thumbnail_cached_in_pending(
            cache_key_base, size, exact_filename
        )
    
    def get_thumbnail_dir_listing(self, force_refresh=False):
        """Get cached thumbnail directory listing, refreshing if needed
        
        CRITICAL: Never refresh from worker threads - this causes GIL deadlock.
        Worker threads should only use cached values. Only main thread refreshes.
        """
        # Check if we're in a worker thread by comparing with main application thread
        try:
            app = QApplication.instance()
            if app:
                current_thread = QThread.currentThread()
                main_thread = app.thread()
                is_main_thread = (current_thread == main_thread)
            else:
                # No app instance - assume main thread
                is_main_thread = True
        except Exception:
            # If we can't determine, assume main thread to be safe
            is_main_thread = True
        
        # If we're not on main thread, NEVER refresh - only use cached value
        # This prevents GIL deadlock when worker threads try to call os.listdir()
        if not is_main_thread:
            snapshot = self.get_thumbnail_dir_snapshot()
            if snapshot:
                return set(snapshot.filenames)
            if self._thumbnail_dir_cache_valid:
                return self._thumbnail_dir_cache
            return set()
        
        if force_refresh or not self._thumbnail_dir_cache_valid:
            self._refresh_thumbnail_dir_cache()
        
        return self._thumbnail_dir_cache
    
    def invalidate_thumbnail_dir_cache(self, *, full: bool = False):
        """Invalidate the thumbnail directory cache.
        
        Default: mark listing stale; keep prefix index until lazy refresh.
        full=True: wipe in-memory index (bulk clear / EXIF setting change).
        """
        self._thumbnail_dir_cache_valid = False
        if full:
            self._thumbnail_dir_cache = set()
            self._thumbnail_prefix_index = {}
            with QMutexLocker(self._pending_index_mutex):
                self._pending_index_adds.clear()
                self._pending_index_removes.clear()
            self._publish_dir_snapshot()
    
    def cleanup(self):
        """Cleanup resources"""
        if self.background_loader:
            self.background_loader.stop()
        
        # Stop the save timer
        if hasattr(self, '_save_timer'):
            self._save_timer.stop()
        
        # Final save of metadata cache
        self.save_metadata_cache(force=True)
    
    def _update_ignore_exif_setting(self):
        """Update the cached ignore_exif_rotation setting from config"""
        try:
            config = get_config()
            settings = config.load_settings()
            self._ignore_exif_rotation = settings.get('ignore_exif_rotation', False)
        except Exception:
            # If we can't get the setting, default to False (EXIF correction enabled)
            self._ignore_exif_rotation = False
    
    def get_ignore_exif_setting(self) -> bool:
        """Get the ignore_exif_rotation setting, using cache if available"""
        if self._ignore_exif_rotation is None:
            self._update_ignore_exif_setting()
        return self._ignore_exif_rotation
    
    def update_exif_setting(self, ignore_exif: bool):
        """Update the ignore_exif_rotation setting (called when setting changes)"""
        old_setting = self._ignore_exif_rotation
        self._ignore_exif_rotation = ignore_exif
        # If setting changed, clear caches
        if old_setting is not None and old_setting != ignore_exif:
            with QMutexLocker(self.cache_mutex):
                self.thumbnail_cache.clear()
                self.fullimage_cache.clear()
            self.invalidate_thumbnail_dir_cache(full=True)
    
    def get_cache_key(self, image_path: str, extra: str = "") -> str:
        """Generate cache key for an image"""
        ignore_exif = self.get_ignore_exif_setting()
        with QMutexLocker(self._stat_cache_mutex):
            return compute_thumbnail_cache_key(
                image_path,
                app_cache_dir=self._app_cache_dir,
                ignore_exif_rotation=ignore_exif,
                stat_cache=self._stat_cache,
                stat_cache_max_age=self._stat_cache_max_age,
                extra=extra,
            )
    
    def get_thumbnail_async(self, image_path: str, size: int, priority: int = 0) -> Optional[QPixmap]:
        """
        Get thumbnail asynchronously. Returns in-memory cache hits immediately;
        otherwise queues for background loading and emits thumbnail_ready when done.
        """
        cache_key_base = self.get_cache_key(image_path)
        exact_cache_key = f"{cache_key_base}_{size}"
        
        # Check for exact size match first (only synchronous fast path — memory hit)
        with QMutexLocker(self.cache_mutex):
            if exact_cache_key in self.thumbnail_cache:
                cached = self.thumbnail_cache[exact_cache_key]
                if cached.size == size:
                    self.stats.thumbnail_hits += 1
                    self._lru_counter += 1
                    self.thumbnail_cache[exact_cache_key] = cached._replace(created_time=self._lru_counter)
                    self.thumbnail_ready.emit(image_path, cached.pixmap, size)
                    return cached.pixmap
        
        # Disk load, scale-down, and generation run on BackgroundImageLoader workers
        # (avoid QPixmap I/O and SmoothTransformation on the UI thread during scroll).
        self.stats.thumbnail_misses += 1
        self.background_loader.add_thumbnail_request(image_path, size, priority)
        return None
    
    def get_thumbnail_sync(self, image_path: str, size: int, thumbnail_dir_listing: Optional[set] = None) -> Optional[QPixmap]:
        """Get thumbnail synchronously (for background thread use)
        
        Args:
            image_path: Path to the image file
            size: Desired thumbnail size
            thumbnail_dir_listing: Optional pre-fetched directory listing to avoid repeated os.listdir() calls
        """
        cache_key_base = self.get_cache_key(image_path)
        exact_cache_key = f"{cache_key_base}_{size}"
        
        # Check in-memory cache - combine both checks into single lock to minimize hold time
        best_cached = None
        best_size = 0
        
        with QMutexLocker(self.cache_mutex):
            # Check for exact size match first
            if exact_cache_key in self.thumbnail_cache:
                cached = self.thumbnail_cache[exact_cache_key]
                if cached.size == size:
                    return cached.pixmap
            
            # OPTIMIZATION: Use index - only check keys for this path (typically 3-5), not whole cache
            base = cache_key_base.split('_')[0] if '_' in cache_key_base else cache_key_base
            for key in self._thumbnail_key_index.get(base, set()):
                cached = self.thumbnail_cache.get(key)
                if cached and cached.size > size:
                    if cached.size > best_size:
                        best_cached = cached
                        best_size = cached.size
        
        if best_cached:
            # Scale down the larger thumbnail to the requested size
            scaled_pixmap = best_cached.pixmap.scaled(
                size, size,
                Qt.KeepAspectRatio,
                Qt.SmoothTransformation
            )
            # Cache the scaled version for future use (outside of mutex to avoid deadlock)
            self._cache_thumbnail_memory(exact_cache_key, scaled_pixmap, size)
            return scaled_pixmap
        
        exact_filename = f"{exact_cache_key}.jpg"
        disk_path = None
        dir_snapshot = self.get_thumbnail_dir_snapshot()
        if dir_snapshot is not None and self._thumbnail_dir_cache_valid:
            if exact_filename in dir_snapshot.filenames:
                disk_path = os.path.join(self.thumbnail_cache_dir, exact_filename)
        elif self._is_main_thread():
            if not self._thumbnail_dir_cache_valid:
                self._refresh_thumbnail_dir_cache()
            if exact_filename in self._thumbnail_dir_cache:
                disk_path = os.path.join(self.thumbnail_cache_dir, exact_filename)
        elif os.path.exists(os.path.join(self.thumbnail_cache_dir, exact_filename)):
            disk_path = os.path.join(self.thumbnail_cache_dir, exact_filename)
        if disk_path:
            try:
                pixmap = QPixmap(disk_path)
                if not pixmap.isNull():
                    self._cache_thumbnail_memory(exact_cache_key, pixmap, size)
                    return pixmap
            except Exception:
                pass
        
        # Check disk cache for larger thumbnails that can be scaled down
        best_disk_size = 0
        best_disk_path = None

        try:
            indexed_variants = None
            if dir_snapshot is not None and self._thumbnail_dir_cache_valid:
                if cache_key_base in dir_snapshot.prefix_index:
                    indexed_variants = dir_snapshot.prefix_index[cache_key_base]
            elif self._is_main_thread():
                if not self._thumbnail_dir_cache_valid:
                    self._refresh_thumbnail_dir_cache()
                if cache_key_base in self._thumbnail_prefix_index:
                    indexed_variants = tuple(self._thumbnail_prefix_index[cache_key_base])
            if indexed_variants:
                for cached_size, filename in indexed_variants:
                    if cached_size >= size and cached_size > best_disk_size:
                        best_disk_size = cached_size
                        best_disk_path = os.path.join(self.thumbnail_cache_dir, filename)
            else:
                if thumbnail_dir_listing is None:
                    thumbnail_files = self.get_thumbnail_dir_listing()
                else:
                    thumbnail_files = thumbnail_dir_listing

                scanned = 0
                max_disk_scan = 200
                for filename in thumbnail_files:
                    scanned += 1
                    if scanned > max_disk_scan:
                        break
                    if filename.startswith(cache_key_base + "_") and filename.endswith('.jpg'):
                        try:
                            cached_size = int(filename.split('_')[-1].replace('.jpg', ''))
                            if cached_size >= size and cached_size > best_disk_size:
                                best_disk_size = cached_size
                                best_disk_path = os.path.join(self.thumbnail_cache_dir, filename)
                        except (ValueError, IndexError):
                            continue

            if best_disk_path:
                pixmap = QPixmap(best_disk_path)
                if not pixmap.isNull():
                    # Scale down the larger thumbnail
                    scaled_pixmap = pixmap.scaled(
                        size, size,
                        Qt.KeepAspectRatio,
                        Qt.SmoothTransformation
                    )
                    # Cache the scaled version for future use (outside of mutex to avoid deadlock)
                    self._cache_thumbnail_memory(exact_cache_key, scaled_pixmap, size)
                    return scaled_pixmap
        except Exception:
            pass
        
        return None
    
    def cache_thumbnail_sync(
        self,
        image_path: str,
        pixmap: QPixmap,
        size: int,
        *,
        defer_index_update: bool = False,
        loader_metadata: Optional[Tuple[int, int, Optional[float]]] = None,
    ):
        """Cache thumbnail synchronously (for background thread use)"""
        if self.is_in_app_cache_directory(image_path):
            return
        
        cache_key = f"{self.get_cache_key(image_path)}_{size}"
        self._cache_thumbnail_memory(cache_key, pixmap, size)
        
        try:
            disk_path = os.path.join(self.thumbnail_cache_dir, f"{cache_key}.jpg")
            pixmap.save(disk_path, "JPEG", quality=85)
            self._queue_index_add(f"{cache_key}.jpg", defer=defer_index_update)
        except Exception:
            pass
        
        if loader_metadata:
            self._cache_metadata_from_loader(image_path, loader_metadata)
        else:
            self._ensure_metadata_exists(image_path)
    
    def _cache_thumbnail_memory(self, cache_key: str, pixmap: QPixmap, size: int):
        """Cache thumbnail in memory with LRU management"""
        with QMutexLocker(self.cache_mutex):
            # Remove oldest entries if cache is full
            if len(self.thumbnail_cache) >= self.max_thumbnail_cache:
                remove_count = self.max_thumbnail_cache // 5
                evict_heap = [
                    (cached.created_time, old_key)
                    for old_key, cached in self.thumbnail_cache.items()
                ]
                for _, old_key in heapq.nsmallest(remove_count, evict_heap):
                    del self.thumbnail_cache[old_key]
                    base = old_key.split('_')[0]
                    if base in self._thumbnail_key_index:
                        self._thumbnail_key_index[base].discard(old_key)
                        if not self._thumbnail_key_index[base]:
                            del self._thumbnail_key_index[base]
            
            # Add new entry with efficient counter
            self._lru_counter += 1
            self.thumbnail_cache[cache_key] = CachedThumbnail(
                pixmap=pixmap,
                size=size,
                created_time=self._lru_counter
            )
            base = cache_key.split('_')[0]
            if base not in self._thumbnail_key_index:
                self._thumbnail_key_index[base] = set()
            self._thumbnail_key_index[base].add(cache_key)
    
    
    def get_metadata_sync(self, image_path: str) -> Optional[ImageMetadata]:
        """Get metadata synchronously (for background thread use)"""
        cache_key = self.get_cache_key(image_path)

        with QMutexLocker(self.cache_mutex):
            metadata = self.metadata_cache.get(cache_key)
        if metadata is None:
            return None

        try:
            if not os.path.exists(image_path):
                with QMutexLocker(self.cache_mutex):
                    self.metadata_cache.pop(cache_key, None)
                return None

            current_source_dir = os.path.dirname(os.path.abspath(image_path))
            if not (
                hasattr(metadata, 'source_directory')
                and metadata.source_directory
                and metadata.source_directory == current_source_dir
            ):
                with QMutexLocker(self.cache_mutex):
                    self.metadata_cache.pop(cache_key, None)
                return None

            now = time.time()
            last_check = self._metadata_validation_times.get(image_path, 0.0)
            if now - last_check < 60.0:
                return metadata

            self._metadata_validation_times[image_path] = now
            if os.environ.get("PROWSER_PROFILE_STARTUP", "").strip().lower() in ("1", "true", "yes"):
                self._metadata_stat_on_hit_count += 1
            with QMutexLocker(self._stat_cache_mutex):
                self._stat_cache.pop(image_path, None)
            fresh_key = self.get_cache_key(image_path)
            if fresh_key != cache_key:
                with QMutexLocker(self.cache_mutex):
                    self.metadata_cache.pop(cache_key, None)
                return None
            return metadata
        except Exception:
            pass

        return None
    
    def cache_metadata_sync(self, image_path: str, metadata: ImageMetadata):
        """Cache metadata synchronously"""
        # Don't cache files that are in the app's cache directory (to avoid duplicates)
        if self.is_in_app_cache_directory(image_path):
            return
        
        cache_key = self.get_cache_key(image_path)
        
        with QMutexLocker(self.cache_mutex):
            # Remove oldest entries if cache is full
            if len(self.metadata_cache) >= self.max_metadata_cache:
                remove_count = self.max_metadata_cache // 5
                # For metadata, we can just remove any random entries since they're lightweight
                keys_to_remove = list(self.metadata_cache.keys())[:remove_count]
                for key in keys_to_remove:
                    del self.metadata_cache[key]
            
            # Ensure metadata has the correct source directory
            if not hasattr(metadata, 'source_directory') or not metadata.source_directory or metadata.source_directory == "Unknown":
                # Fix the source directory if it's missing or incorrect
                correct_source_dir = os.path.dirname(os.path.abspath(image_path))
                metadata = metadata._replace(source_directory=correct_source_dir)
            
            self.metadata_cache[cache_key] = metadata
            
            # Track source directory
            if hasattr(metadata, 'source_directory') and metadata.source_directory and metadata.source_directory != "Unknown":
                self.source_directories.add(metadata.source_directory)
        
        self._metadata_dirty = True
        self._periodic_save()
    
    def cache_metadata_batch_sync(self, metadata_updates: List[Tuple[str, ImageMetadata]], defer_save: bool = False):
        """
        Cache metadata for multiple files in batch (more efficient than individual calls).
        
        Args:
            metadata_updates: List of (image_path, metadata) tuples
            defer_save: If True, don't trigger periodic save (caller will save at end)
        """
        if not metadata_updates:
            return
        
        with QMutexLocker(self.cache_mutex):
            # Remove oldest entries if cache is full (do this once for the batch)
            if len(self.metadata_cache) >= self.max_metadata_cache:
                remove_count = self.max_metadata_cache // 5
                keys_to_remove = list(self.metadata_cache.keys())[:remove_count]
                for key in keys_to_remove:
                    del self.metadata_cache[key]
            
            # Process all updates in batch
            for image_path, metadata in metadata_updates:
                # Don't cache files that are in the app's cache directory
                if self.is_in_app_cache_directory(image_path):
                    continue
                
                cache_key = self.get_cache_key(image_path)
                
                # Ensure metadata has the correct source directory
                if not hasattr(metadata, 'source_directory') or not metadata.source_directory or metadata.source_directory == "Unknown":
                    correct_source_dir = os.path.dirname(os.path.abspath(image_path))
                    metadata = metadata._replace(source_directory=correct_source_dir)
                
                self.metadata_cache[cache_key] = metadata
                
                # Track source directory
                if hasattr(metadata, 'source_directory') and metadata.source_directory and metadata.source_directory != "Unknown":
                    self.source_directories.add(metadata.source_directory)
        
        # Only trigger periodic save if not deferred (caller will save at end of batch)
        if not defer_save:
            self._metadata_dirty = True
            self._periodic_save()
    
    def get_fullimage_sync(self, image_path: str) -> Optional[QPixmap]:
        """Get full image synchronously"""
        cache_key = self.get_cache_key(image_path)
        return self.fullimage_cache.get(cache_key)
    
    def cache_fullimage_sync(self, image_path: str, pixmap: QPixmap):
        """Cache full image synchronously"""
        # Don't cache files that are in the app's cache directory (to avoid duplicates)
        if self.is_in_app_cache_directory(image_path):
            return
        
        cache_key = self.get_cache_key(image_path)
        
        with QMutexLocker(self.cache_mutex):
            # Remove oldest entries if cache is full
            if len(self.fullimage_cache) >= self.max_fullimage_cache:
                # Remove oldest half of entries (full images are memory-intensive)
                remove_count = self.max_fullimage_cache // 2
                keys_to_remove = list(self.fullimage_cache.keys())[:remove_count]
                for key in keys_to_remove:
                    del self.fullimage_cache[key]
            
            self.fullimage_cache[cache_key] = pixmap
    
    def _on_error_occurred(self, path: str, error_message: str):
        """Handle error occurred from background thread"""
        # This signal is not directly connected to a UI signal in the original code,
        # so it doesn't need to be handled here unless it's intended for logging.
        # For now, we'll just print it.
        pass # print(f"Error loading {path}: {error_message}")
    
    def _load_metadata_cache(self):
        """Load persistent metadata cache from disk"""
        if os.path.exists(self.metadata_cache_file):
            try:
                with open(self.metadata_cache_file, 'r') as f:
                    data = json.load(f)
                    for cache_key, metadata_dict in data.items():
                        try:
                            metadata = ImageMetadata(**metadata_dict)
                        except Exception:
                            # Skip invalid metadata entries
                            continue
                        
                        # Only cache metadata with valid source directories
                        if (hasattr(metadata, 'source_directory') and 
                            metadata.source_directory and 
                            metadata.source_directory != "Unknown"):
                            self.metadata_cache[cache_key] = metadata
                            # Track source directory
                            self.source_directories.add(metadata.source_directory)
                        else:
                            # Skip metadata with unknown source directories
                            continue
            except Exception as e:
                pass # print(f"Error loading metadata cache: {e}")
                # If there's an error loading the cache, clear it to force rebuild
                try:
                    os.unlink(self.metadata_cache_file)
                except Exception:
                    pass
    
    def _json_safe(self, val):
        """Convert value to JSON-serializable form (handles numpy, Path, etc.)"""
        if isinstance(val, (str, int, float, bool, type(None))):
            return val
        if isinstance(val, (list, tuple)):
            return [self._json_safe(v) for v in val]
        if isinstance(val, dict):
            return {str(k): self._json_safe(v) for k, v in val.items()}
        return str(val)

    def save_metadata_cache(self, force: bool = False):
        """Save metadata cache to disk"""
        # Copy data while holding mutex, then write outside mutex to avoid blocking
        with QMutexLocker(self.cache_mutex):
            # Compute hash of current valid metadata (sorted, as string)
            current_metadata_for_hash = {
                cache_key: metadata._asdict()
                for cache_key, metadata in self.metadata_cache.items()
                if (hasattr(metadata, 'source_directory') and
                    metadata.source_directory and
                    metadata.source_directory != "Unknown")
            }
            # Serialize deterministically with JSON-safe conversion (numpy, Path, etc.)
            from hashlib import md5
            safe_metadata = self._json_safe(current_metadata_for_hash)
            metadata_json_str = json.dumps(safe_metadata, sort_keys=True, separators=(',', ':'))
            current_hash = md5(metadata_json_str.encode('utf-8')).hexdigest()
            # If hash matches, nothing has changed, return early
            if getattr(self, 'metadata_hash', None) == current_hash and not force:
                self._metadata_dirty = False
                return
            # Update stored hash
            self.metadata_hash = current_hash
            # Use safe_metadata for file write (JSON-serializable)
            valid_metadata = safe_metadata
            self._metadata_dirty = False
            # if len(valid_metadata) > 10000:
            #     # Sort by access time if available, otherwise keep most recent
            #     sorted_items = sorted(valid_metadata.items(), key=lambda x: x[1].get('modified_time', 0), reverse=True)
            #     valid_metadata = dict(sorted_items[:10000])
        
        # Write to disk outside mutex to avoid blocking other threads
        try:
            with open(self.metadata_cache_file, 'w') as f:
                json.dump(valid_metadata, f, indent=2)
        except Exception as e:
            # If there's an error saving, try to remove the corrupted file
            try:
                os.unlink(self.metadata_cache_file)
            except Exception:
                pass
    
    def _periodic_save(self):
        """Periodically save metadata cache to disk"""
        if not self._metadata_dirty:
            return
        current_time = time.time()
        if current_time - self._last_save_time >= self._save_interval:
            self.save_metadata_cache()
            self._last_save_time = current_time
            self._metadata_dirty = False
    
    def set_metadata_changed_notifier(
        self,
        notifier: Optional[Callable[[str, Optional[Set[str]]], None]],
    ) -> None:
        """Register callback invoked when file metadata cache is invalidated."""
        self._metadata_changed_notifier = notifier

    def _emit_metadata_changed(
        self,
        image_path: str,
        fields: Optional[Set[str]] = None,
    ) -> None:
        if self._metadata_changed_notifier:
            try:
                self._metadata_changed_notifier(image_path, fields)
            except Exception:
                traceback.print_exc()

    def clear_cache_for_file(self, image_path: str, *, metadata_fields: Optional[Set[str]] = None):
        """Clear cache for a specific file (but preserve thumbnails)"""
        # Invalidate _stat_cache so get_cache_key/get_sort_key get fresh mtime from disk
        # (critical when mtime was changed by drag/drop or other in-app operations)
        with QMutexLocker(self._stat_cache_mutex):
            self._stat_cache.pop(image_path, None)
        
        cache_key = self.get_cache_key(image_path)
        
        # Remove any pending requests for this file from the background loader
        if self.background_loader:
            self.background_loader.remove_requests_for_file(image_path)
        
        with QMutexLocker(self.cache_mutex):
            # DO NOT remove from thumbnail cache - preserve thumbnails
            # This prevents constant rebuilding when opening directories
            
            # Remove from metadata cache (by current key and by path - handles mtime change)
            if cache_key in self.metadata_cache:
                metadata = self.metadata_cache[cache_key]
                source_dir = getattr(metadata, 'source_directory', None)
                del self.metadata_cache[cache_key]
                if source_dir and source_dir != "Unknown":
                    other_files_in_dir = any(
                        getattr(m, 'source_directory', None) == source_dir
                        for m in self.metadata_cache.values()
                    )
                    if not other_files_in_dir:
                        self.source_directories.discard(source_dir)
            # Also remove metadata under old cache keys (e.g. after mtime change via drag/drop)
            norm_path = os.path.normpath(image_path)
            for key in list(self.metadata_cache.keys()):
                m = self.metadata_cache[key]
                src = getattr(m, 'source_directory', None)
                fn = getattr(m, 'filename', None)
                if src and fn and os.path.normpath(os.path.join(src, fn)) == norm_path:
                    del self.metadata_cache[key]
                    if src != "Unknown":
                        other = any(getattr(x, 'source_directory', None) == src for x in self.metadata_cache.values())
                        if not other:
                            self.source_directories.discard(src)
                    break
            
            # Remove from full image cache
            if cache_key in self.fullimage_cache:
                del self.fullimage_cache[cache_key]
            
            # DO NOT remove from disk cache - preserve thumbnail files
            # This allows thumbnails to persist across directory changes
            self.clear_cache_for_file_logic(image_path)

        self._emit_metadata_changed(image_path, metadata_fields)

    def clear_thumbnails_for_file(self, image_path: str):
        """Clear thumbnails for a specific file (for transformation updates)"""
        
        with QMutexLocker(self.cache_mutex):
           self.clear_cache_for_file_logic(image_path)
    
    def clear_cache_for_file_logic(self, image_path: str, thumbnail_files: Optional[set] = None, skip_disk_deletion: bool = False, defer_invalidate: bool = False):
        """This must be called with the cache mutex held
        
        Args:
            image_path: Path to the image file
            thumbnail_files: Optional pre-fetched directory listing to avoid repeated os.listdir() calls.
            skip_disk_deletion: If True, skip deleting disk cache files.
            defer_invalidate: If True, defer incremental index updates until flush_thumbnail_dir_index().
        """

        cache_key = self.get_cache_key(image_path)
        cache_key_base = cache_key.split('_')[0] if '_' in cache_key else cache_key
        keys_to_remove = list(self._thumbnail_key_index.get(cache_key_base, set()))
        prefix = cache_key_base + "_"
        
        for key in keys_to_remove:
            if key in self.thumbnail_cache:
                del self.thumbnail_cache[key]
        if cache_key_base in self._thumbnail_key_index:
            del self._thumbnail_key_index[cache_key_base]
        
        if not skip_disk_deletion:
            try:
                if thumbnail_files is None:
                    indexed = self._thumbnail_prefix_index.get(cache_key_base)
                    if indexed:
                        for _, filename in indexed:
                            disk_path = os.path.join(self.thumbnail_cache_dir, filename)
                            try:
                                os.unlink(disk_path)
                            except Exception:
                                pass
                            self._queue_index_remove(filename, defer=defer_invalidate)
                    else:
                        thumbnail_files = self.get_thumbnail_dir_listing()
                        for filename in thumbnail_files:
                            if filename.startswith(prefix) and filename.endswith('.jpg'):
                                disk_path = os.path.join(self.thumbnail_cache_dir, filename)
                                try:
                                    os.unlink(disk_path)
                                except Exception:
                                    pass
                                self._queue_index_remove(filename, defer=defer_invalidate)
                else:
                    for filename in thumbnail_files:
                        if filename.startswith(prefix) and filename.endswith('.jpg'):
                            disk_path = os.path.join(self.thumbnail_cache_dir, filename)
                            try:
                                os.unlink(disk_path)
                            except Exception:
                                pass
                            self._queue_index_remove(filename, defer=defer_invalidate)
            except Exception as e:
                print(f"{RED}Error clearing disk cache for {image_path}: {e}")
        
        if not defer_invalidate:
            self._publish_dir_snapshot()
    
    def clear_cache_for_files_batch(
        self,
        image_paths: List[str],
        *,
        metadata_fields: Optional[Set[str]] = None,
    ):
        """Clear cache for multiple files. Use instead of N separate clear_cache_for_file calls.
        Fetches thumbnail dir listing at most once, skips disk deletion during batch (orphaned
        thumbnails cleaned up lazily), invalidates once at end. Much faster for mass rename."""
        if not image_paths:
            return
        for image_path in image_paths:
            with QMutexLocker(self._stat_cache_mutex):
                self._stat_cache.pop(image_path, None)
        for image_path in image_paths:
            if self.background_loader:
                self.background_loader.remove_requests_for_file(image_path)
        with QMutexLocker(self.cache_mutex):
            for image_path in image_paths:
                cache_key = self.get_cache_key(image_path)
                if cache_key in self.metadata_cache:
                    metadata = self.metadata_cache[cache_key]
                    source_dir = getattr(metadata, 'source_directory', None)
                    del self.metadata_cache[cache_key]
                    if source_dir and source_dir != "Unknown":
                        other_files_in_dir = any(
                            getattr(m, 'source_directory', None) == source_dir
                            for m in self.metadata_cache.values()
                        )
                        if not other_files_in_dir:
                            self.source_directories.discard(source_dir)
                if cache_key in self.fullimage_cache:
                    del self.fullimage_cache[cache_key]
                self.clear_cache_for_file_logic(image_path, skip_disk_deletion=True, defer_invalidate=True)
            self.flush_thumbnail_dir_index()
        for image_path in image_paths:
            self._emit_metadata_changed(image_path, metadata_fields)
    
    def clear_cache(self, cache_type: str = "all"):
        """Clear cache"""
        # Clear background loader queue before clearing cache to prevent processing stale requests
        if self.background_loader and self.background_loader.isRunning():
            # Clear the queue to stop processing pending requests
            # Don't set should_stop=True as the loader is persistent and should keep running
            with QMutexLocker(self.background_loader.queue_mutex):
                self.background_loader.load_queue.clear()
                self.background_loader._queued_thumbnails.clear()
        
        with QMutexLocker(self.cache_mutex):
            if cache_type in ["all", "thumbnails"]:
                self.thumbnail_cache.clear()
                self._thumbnail_key_index.clear()
                # Clear disk cache — scan the directory; the in-memory index can miss
                # thumbnails written with deferred index updates (still on disk).
                try:
                    self.flush_thumbnail_dir_index()
                    if os.path.exists(self.thumbnail_cache_dir):
                        for filename in os.listdir(self.thumbnail_cache_dir):
                            if filename.endswith('.jpg'):
                                try:
                                    os.unlink(os.path.join(self.thumbnail_cache_dir, filename))
                                except Exception:
                                    pass
                    self.invalidate_thumbnail_dir_cache(full=True)
                    self._refresh_thumbnail_dir_cache()
                except Exception:
                    pass
            
            if cache_type in ["all", "metadata"]:
                self.metadata_cache.clear()
                # Clear persistent metadata cache file
                try:
                    os.unlink(self.metadata_cache_file)
                except Exception:
                    pass
            
            if cache_type in ["all", "fullimages"]:
                self.fullimage_cache.clear()
    
    def get_cache_info(self) -> dict:
        """Get cache information and statistics"""
        with QMutexLocker(self.cache_mutex):
            result = {
                "thumbnail_count": len(self.thumbnail_cache),
                "metadata_count": len(self.metadata_cache),
                "fullimage_count": len(self.fullimage_cache),
                "cache_dir": self.cache_dir,
                "stats": {
                    "thumbnail_hit_rate": f"{self.stats.hit_rate('thumbnail'):.2%}",
                    "metadata_hit_rate": f"{self.stats.hit_rate('metadata'):.2%}",
                    "fullimage_hit_rate": f"{self.stats.hit_rate('fullimage'):.2%}",
                    "thumbnail_hits": self.stats.thumbnail_hits,
                    "thumbnail_misses": self.stats.thumbnail_misses,
                    "metadata_hits": self.stats.metadata_hits,
                    "metadata_misses": self.stats.metadata_misses,
                    "fullimage_hits": self.stats.fullimage_hits,
                    "fullimage_misses": self.stats.fullimage_misses,
                }
            }
        return result
    
    def get_cache_directories(self) -> list:
        """Get list of directories from which cached files reference"""
        directories = []
        try:
            # Import MIN_THUMBNAIL_SIZE to only count thumbnails of the default size
            from thumbnails.thumbnail_constants import MIN_THUMBNAIL_SIZE
            
            # Load ALL metadata entries from disk (including those with "Unknown" source_directory)
            # This is needed to properly match thumbnails that might have been skipped during normal load
            all_metadata_cache = {}
            if os.path.exists(self.metadata_cache_file):
                try:
                    with open(self.metadata_cache_file, 'r') as f:
                        data = json.load(f)
                        for cache_key, metadata_dict in data.items():
                            try:
                                metadata = ImageMetadata(**metadata_dict)
                                all_metadata_cache[cache_key] = metadata
                            except Exception:
                                # Skip invalid metadata entries
                                continue
                except Exception:
                    pass
            
            # Merge in-memory cache (which may have newer entries) with disk cache
            # In-memory entries take precedence
            all_metadata_cache.update(self.metadata_cache)
            
            source_dirs = {}
            thumbnail_keys_without_metadata = set()
            counted_keys = set()

            if os.path.exists(self.thumbnail_cache_dir):
                thumbnail_files = self.get_thumbnail_dir_listing()
                for filename in thumbnail_files:
                    if not filename.endswith('.jpg'):
                        continue
                    parsed = self._parse_thumbnail_cache_filename(filename)
                    if not parsed:
                        continue
                    base_cache_key, thumbnail_size = parsed
                    if thumbnail_size != MIN_THUMBNAIL_SIZE:
                        continue

                    metadata = all_metadata_cache.get(base_cache_key)
                    if metadata and (
                        hasattr(metadata, 'source_directory')
                        and metadata.source_directory
                        and metadata.source_directory != "Unknown"
                    ):
                        source_dirs.setdefault(metadata.source_directory, set()).add(base_cache_key)
                        counted_keys.add(base_cache_key)
                    elif base_cache_key not in counted_keys:
                        thumbnail_keys_without_metadata.add(base_cache_key)
            
            if thumbnail_keys_without_metadata:
                unknown_dir = "Unknown source"
                if unknown_dir not in source_dirs:
                    source_dirs[unknown_dir] = set()
                source_dirs[unknown_dir].update(thumbnail_keys_without_metadata)
            
            # Convert to list and sort
            for source_dir in sorted(source_dirs.keys()):
                try:
                    home_dir = os.path.expanduser("~")
                    if source_dir.startswith(home_dir):
                        display_dir = source_dir.replace(home_dir, "~", 1)
                    else:
                        display_dir = source_dir
                    
                    # Count unique files (not thumbnails) from this directory
                    file_count = len(source_dirs[source_dir])
                    directories.append(f"{display_dir} ({file_count:,} files)")
                except Exception:
                    continue
                    
        except Exception as e:
            directories = ["Error loading directories"]
        return directories
    
    def _cache_metadata_from_loader(
        self,
        image_path: str,
        loader_metadata: Tuple[int, int, Optional[float]],
    ):
        """Cache metadata using dimensions/EXIF already extracted during thumbnail load."""
        try:
            if not os.path.exists(image_path):
                return
            stat = os.stat(image_path)
            source_dir = os.path.dirname(os.path.abspath(image_path))
            width, height, exif_taken_time = loader_metadata
            metadata = ImageMetadata(
                filename=os.path.basename(image_path),
                file_size=stat.st_size,
                modified_time=stat.st_mtime,
                source_directory=source_dir,
                width=width or 0,
                height=height or 0,
                exif_taken_time=exif_taken_time,
            )
            self.cache_metadata_sync(image_path, metadata)
        except Exception:
            pass

    def _ensure_metadata_exists(self, image_path: str):
        """Ensure metadata exists for an image, creating it if necessary"""
        try:
            # Check if metadata already exists
            existing_metadata = self.get_metadata_sync(image_path)
            if existing_metadata and hasattr(existing_metadata, 'source_directory') and existing_metadata.source_directory and existing_metadata.source_directory != "Unknown":
                return  # Metadata already exists and is valid
            
            # Create metadata if it doesn't exist or is invalid
            
            # Create metadata directly since we're in the main cache manager
            if not os.path.exists(image_path):
                return
            
            stat = os.stat(image_path)
            
            # Always capture the absolute source directory
            source_dir = os.path.dirname(os.path.abspath(image_path))
            
            # Get dimensions and EXIF date/time quickly using fast metadata method
            dimensions = None
            exif_taken_time = None
            try:
                from exif.exif_image_loader import get_image_dimensions_and_exif_date
                result = get_image_dimensions_and_exif_date(image_path)
                if result:
                    dimensions, exif_taken_time = result
            except ImportError:
                # Fallback to dimensions-only if new function not available
                try:
                    from exif.exif_image_loader import get_image_dimensions_fast_metadata
                    dimensions = get_image_dimensions_fast_metadata(image_path)
                except ImportError:
                    pass
            
            # Create metadata with all required fields including dimensions and EXIF date/time
            metadata = ImageMetadata(
                filename=os.path.basename(image_path),
                file_size=stat.st_size,
                modified_time=stat.st_mtime,
                source_directory=source_dir,
                width=dimensions[0] if dimensions else 0,
                height=dimensions[1] if dimensions else 0,
                exif_taken_time=exif_taken_time  # EXIF date/time timestamp, or None if not available
            )
            
            # Cache it immediately (will skip if in app cache directory)
            self.cache_metadata_sync(image_path, metadata)
            
        except Exception as e:
            pass # print(f"Error ensuring metadata exists for {image_path}: {e}")
    
    def clear_cache_for_directory(self, directory_path: str, skip_disk_deletion: bool = True):
        """Clear cache for all image files in a directory (non-recursive)
        
        Args:
            directory_path: Path to directory to clear cache for
            skip_disk_deletion: If True (default), skip deleting disk cache files to reduce blocking.
                               Disk files will be regenerated on next access.
        """
        if not os.path.isdir(directory_path):
            return
        
        # Normalize directory path to absolute path for consistent matching
        abs_dir_path = os.path.abspath(directory_path)
        
        # Get image extensions
        try:
            from thumbnails.thumbnail_constants import get_image_extensions
            image_extensions = get_image_extensions()
        except ImportError:
            # Fallback to common extensions if import fails
            image_extensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.webp']
        
        # Collect image files in directory (non-recursive) and create a set of filenames for matching
        image_files = []
        image_filenames = set()
        try:
            for entry in os.listdir(abs_dir_path):
                entry_path = f"{abs_dir_path.rstrip('/')}/{entry}"
                if os.path.isfile(entry_path):
                    _, ext = os.path.splitext(entry)
                    if ext.lower() in image_extensions:
                        image_files.append(entry_path)
                        image_filenames.add(entry)
        except (OSError, PermissionError):
            # Can't read directory, return early
            return
        
        with QMutexLocker(self.cache_mutex):
            # Strategy: Find cache entries by matching source_directory and filename
            # This handles cases where mtime has changed and cache keys don't match
            keys_to_remove = set()
            
            # First pass: Find all cache entries for files in this directory
            # by matching source_directory and filename (doesn't depend on mtime)
            for cache_key, metadata in list(self.metadata_cache.items()):
                if hasattr(metadata, 'source_directory') and metadata.source_directory:
                    metadata_dir = os.path.abspath(metadata.source_directory)
                    if metadata_dir == abs_dir_path:
                        # Check if this metadata entry matches a file in the directory
                        if hasattr(metadata, 'filename') and metadata.filename in image_filenames:
                            keys_to_remove.add(cache_key)
            
            # Second pass: Also try current cache keys for files (handles unchanged files)
            # This catches files that haven't changed since caching
            for image_path in image_files:
                try:
                    cache_key = self.get_cache_key(image_path)
                    keys_to_remove.add(cache_key)
                except Exception:
                    # If we can't get cache key (e.g., file doesn't exist), skip it
                    pass
            
            # Remove all matching cache entries
            for cache_key in keys_to_remove:
                # Remove from metadata cache
                if cache_key in self.metadata_cache:
                    del self.metadata_cache[cache_key]
                
                # Remove from thumbnail cache (all sizes) - use index for O(k) not O(N)
                cache_key_base = cache_key.split('_')[0] if '_' in cache_key else cache_key
                thumbnail_keys_to_remove = list(self._thumbnail_key_index.get(cache_key_base, set()))
                for key in thumbnail_keys_to_remove:
                    if key in self.thumbnail_cache:
                        del self.thumbnail_cache[key]
                if cache_key_base in self._thumbnail_key_index:
                    del self._thumbnail_key_index[cache_key_base]
                
                # Remove from fullimage cache
                if cache_key in self.fullimage_cache:
                    del self.fullimage_cache[cache_key]
            
            # Clean up source directory tracking
            other_files_in_dir = any(
                getattr(m, 'source_directory', None) == abs_dir_path 
                for m in self.metadata_cache.values()
            )
            if not other_files_in_dir:
                self.source_directories.discard(abs_dir_path)
        
        # Remove any pending requests for these files from the background loader
        if self.background_loader:
            for image_path in image_files:
                self.background_loader.remove_requests_for_file(image_path)
        
        # Clear disk cache files (if not skipping)
        if not skip_disk_deletion:
            try:
                thumbnail_files = self.get_thumbnail_dir_listing(force_refresh=True)
                for image_path in image_files:
                    cache_key = self.get_cache_key(image_path)
                    cache_key_base = cache_key.split('_')[0] if '_' in cache_key else cache_key
                    prefix = cache_key_base + "_"
                    for filename in thumbnail_files:
                        if filename.startswith(prefix) and filename.endswith('.jpg'):
                            disk_path = os.path.join(self.thumbnail_cache_dir, filename)
                            try:
                                os.unlink(disk_path)
                            except Exception:
                                pass
                            self._queue_index_remove(filename)
                self._publish_dir_snapshot()
            except Exception:
                pass  # Ignore disk cache clearing errors
    
    def get_cache_statistics(self) -> dict:
        """Get detailed cache statistics"""
        try:
            total_items = len(self.thumbnail_cache) + len(self.metadata_cache) + len(self.fullimage_cache)
            return {
                "total_cached_items": total_items,
                "thumbnail_cache_items": len(self.thumbnail_cache),
                "metadata_cache_items": len(self.metadata_cache),
                "fullimage_cache_items": len(self.fullimage_cache),
                "disk_usage_bytes": 0,
                "disk_usage_mb": 0.0,
                "cache_directories": self.get_cache_directories(),
                "hit_rates": {
                    "thumbnail": f"{self.stats.hit_rate('thumbnail'):.1%}",
                    "metadata": f"{self.stats.hit_rate('metadata'):.1%}",
                    "fullimage": f"{self.stats.hit_rate('fullimage'):.1%}",
                },
                "total_requests": {
                    "thumbnail": self.stats.thumbnail_hits + self.stats.thumbnail_misses,
                    "metadata": self.stats.metadata_hits + self.stats.metadata_misses,
                    "fullimage": self.stats.fullimage_hits + self.stats.fullimage_misses,
                },
                "dir_cache_full_refresh_count": self._dir_cache_full_refresh_count,
                "dir_cache_incremental_update_count": self._dir_cache_incremental_update_count,
                "metadata_stat_on_hit_count": self._metadata_stat_on_hit_count,
            }
        except Exception as e:
            return {
                "total_cached_items": 0,
                "thumbnail_cache_items": 0,
                "metadata_cache_items": 0,
                "fullimage_cache_items": 0,
                "disk_usage_bytes": 0,
                "disk_usage_mb": 0.0,
                "cache_directories": ["Error loading directories"],
                "hit_rates": {
                    "thumbnail": "0.0%",
                    "metadata": "0.0%",
                    "fullimage": "0.0%",
                },
                "total_requests": {
                    "thumbnail": 0,
                    "metadata": 0,
                    "fullimage": 0,
                }
            }
    
   
# Global cache instance
_cache_manager: Optional[ImageCacheManager] = None

def get_cache_manager() -> ImageCacheManager:
    """Get global cache manager instance"""
    global _cache_manager
    if _cache_manager is None:
        _cache_manager = ImageCacheManager()
    return _cache_manager

def cleanup_cache():
    """Cleanup global cache manager"""
    global _cache_manager
    if _cache_manager:
        _cache_manager.cleanup()
        _cache_manager = None 