#!/usr/bin/env python3
"""Generate swiftie/prowser.php from the reference prowser.php (Swift-only site copy)."""

from __future__ import annotations

import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path("/Users/douglasnadel/dev/testchat/image_browser/prowser.php")
DEST = ROOT / "prowser.php"
INFO_PLIST = ROOT / "swift" / "Prowser" / "Resources" / "Info.plist"

SWIFT_DMG_LATEST = "prowser-swift-latest.dmg"


def read_app_version() -> str:
    with INFO_PLIST.open("rb") as handle:
        plist = plistlib.load(handle)
    version = plist.get("CFBundleShortVersionString")
    if not isinstance(version, str) or not version:
        raise SystemExit(f"Missing CFBundleShortVersionString in {INFO_PLIST}")
    return version


def php_head(app_version: str) -> str:
    """PHP preamble: stable latest DMG URL; SEO version from Swift Info.plist at generate time."""
    safe_version = app_version.replace("\\", "\\\\").replace("'", "\\'")
    version_lines = (
        "<?php\n"
        f"$swift_dmg_basename = '{SWIFT_DMG_LATEST}';\n"
        f"$seo_app_version = '{safe_version}';\n"
        "\n"
        "$download_variants = [\n"
        "    'swift' => [\n"
        "        'path' => './' . $swift_dmg_basename,\n"
        "        'filename' => $swift_dmg_basename,\n"
        "        'summary' => 'Native Swift build for Apple silicon.',\n"
        "        'intro' => 'Native Swift Prowser for macOS (Apple silicon).',\n"
        "    ],\n"
        "];\n"
        "\n"
    )
    return version_lines + PHP_HEAD_SUFFIX


PHP_HEAD_SUFFIX = r'''
function log_download_invisible()
{
    $logfile = __DIR__ . '/log.txt';
    $date = date("Y-m-d H:i:s");
    $ip = $_SERVER['REMOTE_ADDR'] ?? '';
    $ua = $_SERVER['HTTP_USER_AGENT'] ?? '';
    $referer = $_SERVER['HTTP_REFERER'] ?? '';
    file_put_contents($logfile, "$date\t$ip\t$ua\t$referer\n", FILE_APPEND | LOCK_EX);
}

function format_time_ago($filetime)
{
    $now = time();
    $diff = $now - $filetime;
    $days = floor($diff / 86400);
    $hours = floor(($diff % 86400) / 3600);
    $minutes = floor(($diff % 3600) / 60);
    $ago_parts = [];
    if ($days > 0) {
        $ago_parts[] = $days . ' day' . ($days !== 1 ? 's' : '');
    }
    if ($hours > 0) {
        $ago_parts[] = $hours . ' hr' . ($hours !== 1 ? 's' : '');
    }
    if ($minutes > 0 || empty($ago_parts)) {
        $ago_parts[] = $minutes . ' min' . ($minutes !== 1 ? 's' : '');
    }
    return implode(', ', $ago_parts) . ' ago';
}

function resolve_swift_dmg_release_version(string $latestPath): ?string
{
    $latestFsPath = $latestPath;
    if (strncmp($latestPath, './', 2) === 0) {
        $latestFsPath = __DIR__ . substr($latestPath, 1);
    } elseif ($latestPath !== '' && $latestPath[0] !== '/') {
        $latestFsPath = __DIR__ . '/' . $latestPath;
    }
    if (!is_file($latestFsPath)) {
        return null;
    }
    $size = filesize($latestFsPath);
    $mtime = filemtime($latestFsPath);
    if ($size === false || $mtime === false) {
        return null;
    }
    $patterns = [
        __DIR__ . '/prowser-swift-*.dmg',
        __DIR__ . '/Prowser-swift-*.dmg',
    ];
    foreach ($patterns as $pattern) {
        foreach (glob($pattern) ?: [] as $path) {
            $base = basename($path);
            if (preg_match('/-latest\.dmg$/i', $base)) {
                continue;
            }
            if (strpos($base, '-min.dmg') !== false) {
                continue;
            }
            if (!preg_match('/^(?:prowser|Prowser)-swift-(\d+\.\d+\.\d+)\.dmg$/i', $base, $match)) {
                continue;
            }
            $candidateSize = @filesize($path);
            $candidateMtime = @filemtime($path);
            if ($candidateSize === false || $candidateMtime === false) {
                continue;
            }
            if ((int) $candidateSize === (int) $size && (int) $candidateMtime === (int) $mtime) {
                return $match[1];
            }
        }
    }
    return null;
}

function get_dmg_info($path)
{
    if (!file_exists($path)) {
        return [
            'available' => false,
            'date' => 'File not found',
            'ago' => '',
            'size_bytes' => 0,
            'size_mb' => '',
            'md5sum' => '',
        ];
    }

    $filetime = filemtime($path);
    $size_bytes = filesize($path);

    return [
        'available' => true,
        'date' => date("Y-m-d H:i", $filetime),
        'ago' => format_time_ago($filetime),
        'size_bytes' => $size_bytes,
        'size_mb' => number_format($size_bytes / (1024 * 1024), 0) . ' MB',
        'md5sum' => md5_file($path),
    ];
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['download_dmg'])) {
    $variant = $_POST['download_dmg'];
    if ($variant === 'swift' && isset($download_variants['swift'])) {
        $chosen = $download_variants['swift'];
        if (file_exists($chosen['path'])) {
            log_download_invisible();
            header('Location: ./' . $chosen['filename']);
            exit;
        }
    }
}

foreach ($download_variants as $key => $variant) {
    $download_variants[$key] = array_merge($variant, get_dmg_info($variant['path']));
}

$swift_dmg_release_version = $seo_app_version;
if (!empty($download_variants['swift']['available'])) {
    $resolved_swift_version = resolve_swift_dmg_release_version($download_variants['swift']['path']);
    if ($resolved_swift_version !== null) {
        $swift_dmg_release_version = $resolved_swift_version;
        $seo_app_version = $resolved_swift_version;
    }
}

$dmg_available = !empty($download_variants['swift']['available']);

$settings_sim_display_width = (int) round(640 * 1.2);
$settings_sim_ref_width = 1550;
$settings_sim_ref_height = 1416;
$settings_sim_default_image = 'settings_general.webp';
$settings_sim_tab_left = 11;
$settings_sim_tab_right = 148;
$settings_sim_tab_top0 = 53;
$settings_sim_tab_height = 20;
$settings_sim_tab_step = 26.5;
$settings_sim_tabs = [
    ['label' => 'General', 'image' => 'settings_general.webp'],
    ['label' => 'Favorites', 'image' => 'settings_favorites.webp'],
    ['label' => 'Directories', 'image' => 'settings_directories.webp'],
    ['label' => 'File Types', 'image' => 'settings_filetypes.webp'],
    ['label' => 'Destinations', 'image' => 'settings_destinations.webp'],
    ['label' => 'Excludes', 'image' => 'settings_excludes.webp'],
    ['label' => 'Theme', 'image' => 'settings_theme.webp'],
    ['label' => 'Maps and Editor', 'image' => 'settings_maps_and_editor.webp'],
    ['label' => 'Slideshow', 'image' => 'settings_slideshow.webp'],
    ['label' => 'Models for Search', 'image' => 'settings_search_models.webp'],
    ['label' => 'Face Recognition', 'image' => 'settings_face_recognition.webp'],
    ['label' => 'Image Generation', 'image' => 'settings_captioning.webp'],
    ['label' => 'LoRA', 'image' => 'settings_LoRA.webp'],
    ['label' => 'Caches', 'image' => 'settings_caches.webp'],
];

$settings_sim_native_width = $settings_sim_ref_width;
$settings_sim_native_height = $settings_sim_ref_height;
$settings_sim_probe = @getimagesize(__DIR__ . '/' . $settings_sim_default_image);
if ($settings_sim_probe !== false) {
    $settings_sim_native_width = (int) $settings_sim_probe[0];
    $settings_sim_native_height = (int) $settings_sim_probe[1];
}
$settings_sim_scale_x = $settings_sim_native_width / $settings_sim_ref_width;
$settings_sim_scale_y = $settings_sim_native_height / $settings_sim_ref_height;

// Bust browser/CDN cache when screenshot files are replaced after tab reorders.
function settings_sim_image_url($image)
{
    $path = __DIR__ . '/' . $image;
    $version = is_file($path) ? (string) filemtime($path) : '1';
    return $image . '?v=' . rawurlencode($version);
}

foreach ($settings_sim_tabs as $i => $tab) {
    $settings_sim_tabs[$i]['url'] = settings_sim_image_url($tab['image']);
}
$settings_sim_default_url = settings_sim_image_url($settings_sim_default_image);
$settings_sim_preload_images = [];
foreach ($settings_sim_tabs as $tab) {
    if ($tab['image'] !== $settings_sim_default_image) {
        $settings_sim_preload_images[] = $tab['url'];
    }
}

'''

MENU_SIM_MOVE_DESTINATIONS = '''$menu_sim_move_destinations_items = [
    menu_sim_item('Move to Directory…'),
    menu_sim_divider(),
    menu_sim_item('Move to Destination 1', '⌘1'),
    menu_sim_item('… more destinations …'),
    menu_sim_item('Move to Destination 9', '⌘9'),
    menu_sim_divider(),
    menu_sim_item('Move to Last Drop Location', '⌘0'),
    menu_sim_item('Move Work Files…'),
    menu_sim_divider(),
    menu_sim_item('Edit Destinations…'),
];
'''

MENU_SIM_SORT = '''$menu_sim_sort_items = [
    menu_sim_item('Date (Newest First)', 'D'),
    menu_sim_item('Date (Oldest First)', '⇧D'),
    menu_sim_item('EXIF Date (Newest First)', 'X'),
    menu_sim_item('EXIF Date (Oldest First)', '⇧X'),
    menu_sim_item('EXIF Year (Newest First)', 'Y'),
    menu_sim_item('EXIF Year (Oldest First)', '⇧Y'),
    menu_sim_item('Name (A-Z)', 'N'),
    menu_sim_item('Name (Z-A)', '⇧N'),
    menu_sim_item('Size (Largest First)', 'Z'),
    menu_sim_item('Size (Smallest First)', '⇧Z'),
    menu_sim_divider(),
    menu_sim_item('Reverse Sort Order', '⌘T'),
    menu_sim_item('Random Sort'),
    menu_sim_item('Custom Sort', 'C'),
];
'''

MENU_SIM_MENUS = r'''$menu_sim_menus = [
    [
        'title' => 'Prowser',
        'app' => true,
        'items' => [
            menu_sim_item('About Prowser'),
            menu_sim_divider(),
            menu_sim_item('Preferences…', '⌘,'),
            menu_sim_divider(),
            menu_sim_item('Quit Prowser', '⌘Q'),
        ],
    ],
    [
        'title' => 'File',
        'items' => [
            menu_sim_item('Open File…', '⇧⌘O'),
            menu_sim_item('Open Directory…', '⌘O'),
            menu_sim_item('Refresh', '⌘R'),
            menu_sim_divider(),
            menu_sim_item('Move File to Trash', '⌘⌫'),
            menu_sim_divider(),
            menu_sim_item('View Copy of Trash…', '⇧⌘T'),
            menu_sim_divider(),
            menu_sim_submenu('Recent…', [menu_sim_item('From your settings')]),
            menu_sim_submenu('Favorites', [menu_sim_item('From your settings')]),
            menu_sim_item('Last Image', '⌘;'),
            menu_sim_item('Image History', 'F3'),
            menu_sim_divider(),
            menu_sim_item('Back', '⌘['),
            menu_sim_item('Forward', '⌘]'),
            menu_sim_item('Reveal in Finder', '⇧⌘R'),
            menu_sim_divider(),
            menu_sim_item('Close Window', '⌘W'),
        ],
    ],
    [
        'title' => 'Edit',
        'items' => [
            menu_sim_item('Select All', '⌘A'),
            menu_sim_divider(),
            menu_sim_item('Copy Path', '⌘C'),
            menu_sim_item('Copy Image', '⌃C'),
            menu_sim_item('Copy User Comment'),
            menu_sim_divider(),
            menu_sim_item('Undo', '⌘Z'),
            menu_sim_divider(),
            menu_sim_item('Rename with Custom Prefix…', '⌘N'),
            menu_sim_item('Convert Image Format…', '⌘M'),
            menu_sim_item('Resize…', '⇧⌘Z'),
            menu_sim_divider(),
            menu_sim_item('Edit with {Editor of your choice}…', '⌘E'),
            menu_sim_divider(),
            menu_sim_item('Deselect All'),
        ],
    ],
    [
        'title' => 'View',
        'items' => [
            menu_sim_item('Enter Image Viewer', 'F'),
            menu_sim_divider(),
            menu_sim_item('Hide / Show File Tree', 'T'),
            menu_sim_item('Hide / Show Information Sidebar', 'I'),
            menu_sim_item('Hide / Show Preview', 'P'),
            menu_sim_item('Hide / Show Chat', 'F9, ,'),
            menu_sim_item('Hide / Show Jobs Pane', 'J'),
            menu_sim_item('Hide / Show Organize Sidebar', 'O'),
            menu_sim_item('Hide / Show Status Bar', 'B'),
            menu_sim_item('Hide / Show List View', 'F12'),
            menu_sim_divider(),
            menu_sim_submenu('Sort By', $menu_sim_sort_items),
            menu_sim_item('Actual Size'),
            menu_sim_item('Cycle Thumbnail Overlay', '⌘I'),
            menu_sim_divider(),
            menu_sim_submenu('Theme', $menu_sim_theme_items),
            menu_sim_item('Show in MacOS Space', '⌃⌘F'),
            menu_sim_item('Hide / Show Chrome', '., ⌃.'),
        ],
    ],
    [
        'title' => 'Search',
        'items' => [
            menu_sim_item('Search for Similar Images…', '⌘K'),
            menu_sim_item('Search by Text…', '⌘F'),
            menu_sim_item('Search for Known Person…', '⌘P'),
            menu_sim_item('Search for Person in Current Image…', '⌃⌘P'),
            menu_sim_item('Identify Faces in Current Image…', '⇧⌘P'),
            menu_sim_submenu('Find Duplicate Image Files', [
                menu_sim_item('Find in This Directory'),
                menu_sim_item('Find in This and Subdirectories'),
            ]),
            menu_sim_submenu('Find Similar Image Files', [
                menu_sim_item('Find in This Directory'),
                menu_sim_item('Find in This and Subdirectories'),
            ]),
            menu_sim_item('Show Image in Directory', '⇧⌘H'),
        ],
    ],
    [
        'title' => 'Move to',
        'items' => $menu_sim_move_destinations_items,
    ],
    [
        'title' => 'Filter',
        'items' => $menu_sim_filter_items,
    ],
    [
        'title' => 'Image',
        'items' => [
            menu_sim_item('Create an image from text…'),
            menu_sim_item('Fast Open Image Generation', '⇧⌥/'),
            menu_sim_divider(),
            menu_sim_item('Edit this image with AI…'),
            menu_sim_item('Expand this image…'),
            menu_sim_item('Infill / paint this image…'),
            menu_sim_divider(),
            menu_sim_item('Cancel Generation'),
            menu_sim_divider(),
            menu_sim_item('Toggle Job Queue', '⌘J'),
            menu_sim_divider(),
            menu_sim_item('Manage models…'),
            menu_sim_item('Test LoRAs…'),
            menu_sim_item('Map LoRAs…'),
        ],
    ],
    [
        'title' => 'Tools',
        'items' => [
            menu_sim_item('Quick Mass Rename…', '⇧⌘M'),
            menu_sim_item('Backup Custom Sort'),
            menu_sim_item('Restore Custom Sort'),
            menu_sim_item('Lock Selected File', '⌘L'),
            menu_sim_item('Unlock Selected File', '⇧⌘L'),
            menu_sim_submenu('EXIF and Dates', [
                menu_sim_item('Reset File Date to EXIF Timestamp…'),
                menu_sim_item('Reset EXIF Timestamp to File Date…'),
                menu_sim_item('Delete EXIF Date from File…'),
                menu_sim_divider(),
                menu_sim_item('Edit EXIF User Comment…', '⇧⌘E'),
                menu_sim_item('Delete User Comment from File…'),
                menu_sim_divider(),
                menu_sim_item('Find References to This Image…'),
            ]),
            menu_sim_item('Show GPS Location on Map', '⌘G'),
            menu_sim_submenu('Slideshows', [
                menu_sim_item('Multiple Images Slideshow', 'S'),
                menu_sim_item('Panning Slideshow', '⇧S'),
                menu_sim_item('Floating Frames Slideshow', '⇧⌃S'),
            ]),
            menu_sim_submenu('Wallpaper', [
                menu_sim_item('Set Wallpaper (Last Used)', '⇧⌘W'),
                menu_sim_item('Fit (Contain)'),
                menu_sim_item('Fill (Cover)'),
                menu_sim_item('Fit to Width'),
                menu_sim_item('Fit to Height'),
            ]),
            menu_sim_submenu('Create Screen Size Copy…', [
                menu_sim_item('Create Screen Size Copy (Last Used)', '⇧⌘U'),
                menu_sim_divider(),
                menu_sim_item('Fit (Contain)'),
                menu_sim_item('Fill (Cover)'),
                menu_sim_item('Fit to Width'),
                menu_sim_item('Fit to Height'),
            ]),
            menu_sim_item('Open Home Directory', '⌃H'),
            menu_sim_item('Favorite prompts…'),
            menu_sim_item('Prefix and Postfix text…'),
            menu_sim_item("Cache Subdirectories' Thumbnails", '⇧⌘C'),
            menu_sim_item("Cache Subdirectories' Faces", '⌘='),
            menu_sim_item('Exclude Thumbs from View', '⌘X'),
            menu_sim_submenu('Debug', [
                menu_sim_item('Random Images'),
                menu_sim_item('View log', '⌃L'),
                menu_sim_item('Show EXIF API Structure'),
                menu_sim_item('Documentation screencaps'),
                menu_sim_divider(),
                menu_sim_item('Reset window geometries…'),
                menu_sim_item('Enable Compatible LoRAs'),
                menu_sim_item('Import Lora Defaults'),
                menu_sim_item('Toggle Debug Mode', '⇧⌘D'),
                menu_sim_item('Remove Facial Rec Models'),
            ]),
        ],
    ],
    [
        'title' => 'Help',
        'items' => [
            menu_sim_item('Keyboard Shortcuts', '/'),
            menu_sim_item('Hidden Gems…'),
            menu_sim_item('Downloading AI Models…'),
            menu_sim_item('Image Search (Native)…'),
        ],
    ],
];
'''

SEO_BLOCK = '''// SEO: absolute URLs and shared copy
$seo_title = 'Prowser — macOS Image Browser (Swift)';
$seo_description = 'Prowser (Personal Image Browser) for Apple silicon Macs: a native Swift app to browse photo folders without importing, with search, organization, and local AI tools.';
$seo_keywords = 'Prowser, macOS, Apple silicon, image browser, photo viewer, Swift, similarity search, face search, duplicate photos, local AI image editing, photo organization, EXIF, keyboard shortcuts, free Mac software, Doug Nadel';
'''


def main() -> None:
    app_version = read_app_version()
    text = SOURCE.read_text(encoding="utf-8")

    marker = "// --- Menu bar simulation"
    idx = text.index(marker)
    text = php_head(app_version) + "\n" + marker + text[idx + len(marker) :]

    text = re.sub(
        r"\$menu_sim_sort_items = \[.*?\];",
        MENU_SIM_SORT.strip(),
        text,
        count=1,
        flags=re.S,
    )

    if re.search(r"\$menu_sim_move_destinations_items = \[", text):
        text = re.sub(
            r"\$menu_sim_move_destinations_items = \[.*?\];",
            MENU_SIM_MOVE_DESTINATIONS.strip(),
            text,
            count=1,
            flags=re.S,
        )
    else:
        text = text.replace(
            "$menu_sim_menus = [",
            MENU_SIM_MOVE_DESTINATIONS.strip() + "\n\n$menu_sim_menus = [",
            1,
        )

    text = re.sub(
        r"\$menu_sim_menus = \[.*?\n\];\r?\n\r?\n// SEO:",
        MENU_SIM_MENUS.strip() + "\n\n// SEO:",
        text,
        count=1,
        flags=re.S,
    )

    text = re.sub(
        r"// SEO: absolute URLs and shared copy\n\$seo_title = .*?\$seo_keywords = '[^']*';",
        SEO_BLOCK.strip(),
        text,
        count=1,
        flags=re.S,
    )

    text = text.replace("$seo_python_version", "$seo_app_version")
    text = text.replace("'name' => $is_swift ? 'Prowser (Swift)' : 'Prowser (Python)'", "'name' => 'Prowser'")
    text = text.replace(
        "'description' => $is_swift\n                ? 'Native Swift macOS image browser with robust image search, organization tools, and some local AI image generation.'\n                : 'Python-based macOS image browser with robust image search, organization tools, and some local AI image generation.'",
        "'description' => 'Native Swift macOS image browser with robust image search, organization tools, and local AI image generation.'",
    )

    # Drop unavailable variants in JSON-LD (only swift remains).
    text = text.replace("$is_swift = ($variant_key === 'swift');\n        ", "")
    text = text.replace("$software_id = $seo_canonical . '#software-' . $variant_key;", "$software_id = $seo_canonical . '#software';")

    intro_html = '''                    <p>
                        Prowser (<b><u>P</u></b>ersonal Image B<b><u>rowser</u></b>) is a native, <b>open source</b> Swift
                        image browser built for macOS on Apple silicon.
                    </p>
                    <p>It reads directly from your existing folders — no import step — and gives you keyboard-driven
                        navigation, powerful search, and practical organization tools in one app.
                    </p>
                    <p>The app is under active development and should be considered beta software.</p>'''

    text = re.sub(
        r"<section class=\"card intro-card\"[^>]*>.*?<h2 id=\"about-prowser-heading\">About Prowser</h2>\s*.*?</section>",
        '<section class="card intro-card" aria-labelledby="about-prowser-heading">\n'
        '                    <h2 id="about-prowser-heading">About Prowser</h2>\n' + intro_html + '\n                </section>',
        text,
        count=1,
        flags=re.S,
    )

    text = text.replace(
        '$install_app_name = ($variant_key === \'swift\') ? \'swift-prowser\' : \'Prowser\';',
        "$install_app_name = 'swift-prowser';",
    )
    text = re.sub(
        r"<p>To run from source instead, save the included source folder and\s*run<br>.*?</p>\s*",
        "",
        text,
        count=1,
        flags=re.S,
    )

    download_note = '''        <p class="download-note">
            Source code is included in the disk image. Project home:
            <a href="https://github.com/Waltz49/Prowser" target="_blank" rel="noopener noreferrer">Prowser on GitHub</a>.
        </p>'''
    text = re.sub(
        r"<p class=\"download-note\">.*?</p>\s*<p> Questions",
        download_note + "\n        <p> Questions",
        text,
        count=1,
        flags=re.S,
    )

    text = text.replace(
        '<li class="features-section-label" role="presentation">——— Both Versions ———</li>',
        "",
    )

    text = text.replace(
        '<h2 id="menu-sim-heading">Quick Look (Python Version)</h2>',
        '<h2 id="menu-sim-heading">Quick Look (Swift)</h2>',
    )
    text = text.replace(
        '<p class="subtitle menu-sim-hint">Note that these screenshots are slightly out of date.</p>',
        '<p class="subtitle menu-sim-hint">Menu bar reflects the Swift app; screenshots update from Tools → Debug → Documentation screencaps.</p>',
    )

    # Scale settings tab hotspots for actual-size WebP captures.
    imagemap_coords = r'''                        <?php foreach ($settings_sim_tabs as $tab_index => $tab) {
                        $top = ($settings_sim_tab_top0 + ($tab_index * $settings_sim_tab_step)) * $settings_sim_scale_y;
                        $bottom = $top + ($settings_sim_tab_height * $settings_sim_scale_y);
                        $left = $settings_sim_tab_left * $settings_sim_scale_x;
                        $right = $settings_sim_tab_right * $settings_sim_scale_x;
                        $coords = round($left) . ',' . round($top) . ','
                            . round($right) . ',' . round($bottom);
                        ?>'''

    text = re.sub(
        r"<\?php foreach \(\$settings_sim_tabs as \$tab_index => \$tab\) \{\s*\$top = \$settings_sim_tab_top0.*?\?>",
        imagemap_coords.strip(),
        text,
        count=1,
        flags=re.S,
    )

    text = text.replace(
        "// --- Menu bar simulation (mirrors menu_manager.py + image_gen_menu.py) ---",
        "// --- Menu bar simulation (mirrors swift/Prowser/UI/Menus/ProwserCommands.swift) ---",
    )

    text = re.sub(
        r"(\.meta-row \{\s*display: flex;\s*flex-wrap: wrap;\s*)gap: 0\.35rem 0\.5rem;\s*"
        r"margin-bottom: 0\.35rem;\s*font-size: 0\.8125rem;",
        r"\1gap: 0.15rem 0.5rem;\n            margin-bottom: 0.12rem;\n            font-size: 0.8125rem;\n            line-height: 1.2;",
        text,
        count=1,
        flags=re.S,
    )

    download_meta_version = '''                                            <div class="download-meta">
                                                <?php if ($variant_key === 'swift' && !empty($swift_dmg_release_version)) { ?>
                                                <div class="meta-row">
                                                    <span class="meta-label">Current version</span>
                                                    <span
                                                        class="meta-value"><?php echo htmlspecialchars($swift_dmg_release_version); ?></span>
                                                </div>
                                                <?php } ?>
                                                <div class="meta-row">
                                                    <span class="meta-label">Last updated</span>'''

    text = text.replace(
        '''                                            <div class="download-meta">
                                                <div class="meta-row">
                                                    <span class="meta-label">Last updated</span>''',
        download_meta_version,
        1,
    )

    DEST.write_text(text, encoding="utf-8")
    print(f"Wrote {DEST}")


if __name__ == "__main__":
    main()