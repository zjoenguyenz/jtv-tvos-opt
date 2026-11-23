// =============================================================================
// CONFIGURATION & METADATA
// =============================================================================

function getManifest() {
    return JSON.stringify({
        "id": "missav",
        "name": "MissAV",
        "version": "1.1.7",
        "baseUrl": "https://missav.media",
        "referrer": "https://missav123.com/",
        "iconUrl": "https://missav.media/favicon.ico",
        "isEnabled": true,
        "isAdult": true,
        "type": "MOVIE",
        "layoutType": "HORIZONTAL",
        "subtitleCat": true
    });
}

function getHomeSections() {
    return JSON.stringify([
        { slug: 'vi/today-hot', title: 'Hot Hôm Nay', type: 'Horizontal', path: '' },
        { slug: 'vi/weekly-hot', title: 'Hot Trong Tuần', type: 'Horizontal', path: '' },
        { slug: 'vi/monthly-hot', title: 'Hot Trong Tháng', type: 'Horizontal', path: '' },
        { slug: 'vi/uncensored-leak', title: 'Không Che (Rò Rỉ)', type: 'Horizontal', path: '' },
        { slug: 'vi/release', title: 'Mới Cập Nhật', type: 'Grid', path: '' }
    ]);
}

function getPrimaryCategories() {
    return JSON.stringify([
        { name: 'Mới cập nhật', slug: 'vi/new' },
        { name: 'Nữ diễn viên', slug: 'vi/actresses' },
        { name: 'Thể loại', slug: 'vi/genres' },
        { name: 'Không che', slug: 'vi/uncensored-leak' },
        { name: "FC2", slug: "vi/fc2" },
        { name: "HEYZO", slug: "vi/heyzo" },
        { name: "Tokyo Hot", slug: "vi/tokyohot" },
        { name: "1pondo", slug: "vi/1pondo" },
        { name: "Caribbeancom", slug: "vi/caribbeancom" },
        { name: "Caribbeancompr", slug: "vi/caribbeancompr" },
        { name: "10musume", slug: "vi/10musume" },
        { name: "pacopacomama", slug: "vi/pacopacomama" },
        { name: "Gachinco", slug: "vi/gachinco" },
        { name: "XXX-AV", slug: "vi/xxx-av" },
        { name: "MarriedSlash", slug: "vi/marriedslash" },
        { name: "Naughty4610", slug: "vi/naughty4610" },
        { name: "Naughty0930", slug: "vi/naughty0930" }
    ]);
}
function getFilterConfig() {
    return JSON.stringify({
        sort: [
            { name: 'Mới nhất', value: 'new' },
            { name: 'Xem nhiều', value: 'views' },
            { name: 'Hôm nay', value: 'today_views' },
            { name: 'Tuần này', value: 'weekly_views' },
            { name: 'Tháng này', value: 'monthly_views' }
        ],
        category: [
            { name: "Tất cả thể loại", value: "vi/genres" },
            { name: "Mới cập nhật", value: "vi/new" },
            { name: "Phát hành mới", value: "vi/release" },
            { name: "Không che (Rò rỉ)", value: "vi/uncensored-leak" },
            { name: "Nữ diễn viên", value: "vi/actresses" },
            { name: "BXH Diễn viên", value: "vi/actresses/ranking" },
            { name: "Nhà sản xuất", value: "vi/makers" },
            { name: "VR", value: "vi/genres/VR" },
            { name: "Xem nhiều hôm nay", value: "vi/today-hot" },
            { name: "Xem nhiều tuần", value: "vi/weekly-hot" },
            { name: "Xem nhiều tháng", value: "vi/monthly-hot" },
            { name: "Phụ đề Anh", value: "vi/english-subtitle" },
            { name: "Phụ đề China", value: "vi/chinese-subtitle" }, // Mapped from old config, keeping consistency 

            // Amateur
            { name: "SIRO", value: "vi/series/SIRO" },
            { name: "LUXU", value: "vi/series/LUXU" },
            { name: "GANA", value: "vi/series/GANA" },
            { name: "MAAN", value: "vi/series/MAAN" },
            { name: "S-CUTE", value: "vi/series/S-CUTE" },
            { name: "ARA", value: "vi/series/ARA" },

            // Uncensored Brands
            { name: "FC2", value: "vi/series/FC2" },
            { name: "HEYZO", value: "vi/series/HEYZO" },
            { name: "Tokyo Hot", value: "vi/series/Tokyo-Hot" },
            { name: "1pondo", value: "vi/series/1pondo" },
            { name: "Caribbeancom", value: "vi/series/Caribbeancom" },
            { name: "Caribbeancompr", value: "vi/series/Caribbeancompr" },
            { name: "10musume", value: "vi/series/10musume" },
            { name: "pacopacomama", value: "vi/series/pacopacomama" },
            { name: "Gachinco", value: "vi/series/Gachinco" },
            { name: "XXX-AV", value: "vi/series/XXX-AV" },
            { name: "MarriedSlash", value: "vi/series/MarriedSlash" },
            { name: "Naughty4610", value: "vi/series/naughty4610" },
            { name: "Naughty0930", value: "vi/series/naughty0930" }
        ]
    });
}

// =============================================================================
// URL GENERATION
// =============================================================================

// Catalogue mirrors (v1.1.5): missav.media / missav.live / missav123.com are
// interchangeable front-ends on ONE backend — identical catalogues and
// identical stream UUIDs on title pages (RESEARCH-MISSAV §1–§2). The plugin
// contract has no fetch-failure callback: the app fetches the URL we return
// and never reports the outcome back. Rotation is therefore attempt-based —
// every URL we hand out takes the NEXT mirror in the list, so a dead mirror
// costs at most one failed load (the app's retry, or the next navigation,
// lands on another mirror) instead of every browse dying with the first
// domain. Playback is unaffected by which mirror served a page: the stream
// URL is always rebuilt on surrit.com from the extracted UUID.
var MISSAV_CATALOG_MIRRORS = [
    "https://missav.media",
    "https://missav.live",
    "https://missav123.com"
];
var _missavMirrorCursor = 0;
function missavCatalogBase() {
    var base = MISSAV_CATALOG_MIRRORS[_missavMirrorCursor % MISSAV_CATALOG_MIRRORS.length];
    _missavMirrorCursor++;
    return base;
}

function getUrlList(slug, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    var baseUrl = missavCatalogBase();

    // If slug is empty (default), use 'vi/new'
    var path = slug || "vi/new";

    // Ensure path starts with /
    if (path.indexOf("/") !== 0) path = "/" + path;

    // Handle pagination (Slug handling with slash protection)
    var pathStr = path;
    if (pathStr.indexOf("/") === 0) pathStr = pathStr.substring(1);

    var url = baseUrl + "/" + pathStr + "?page=" + page;

    // Append sort parameter if applicable
    if (filters.sort && filters.sort !== 'new' && filters.sort !== 'hot') {
        url += "&sort=" + filters.sort;
    } else if (filters.sort === 'hot') {
        url += "&sort=views";
    }

    return url;
}

function getUrlSearch(keyword, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    return missavCatalogBase() + "/vi/search/" + encodeURIComponent(keyword) + "?page=" + page;
}

function getUrlDetail(slug) {
    if (slug.indexOf("http") === 0) return slug;
    if (slug.indexOf("/") === 0) return missavCatalogBase() + slug;
    return missavCatalogBase() + "/vi/" + slug;
}

function getUrlCategories() { return missavCatalogBase() + "/vi/genres"; }
function getUrlCountries() { return ""; } // Not supported
function getUrlYears() { return ""; } // Not supported

// =============================================================================
// PARSERS
// =============================================================================

var PluginUtils = {
    /**
     * Strip các prefix dạng missav<domain>- khỏi CSS class names.
     * Ví dụ: class="missav_media-thumbnail missav_media-group" -> class="thumbnail group"
     * Điều này đảm bảo parser hoạt động với cả HTML cũ và mới.
     */
    normalizeHtml: function (html) {
        if (!html) return "";
        // Strip prefix missav<domain>- trong class attributes. Các dạng
        // theo quy ước domain (dấu chấm -> "_"): missav_media- (.media),
        // missav_live-, missav_ws-, missav123_com- và missav123com-
        // (missav123.com — domain chứa số nên hai dạng của nó KHÔNG bắt
        // đầu bằng "missav_"). Cùng họ prefix trên các mirror chị em từ
        // v1.1.5, khi trang có thể do mirror khác phục vụ.
        // Match neo ở đầu token class (đầu chuỗi hoặc sau khoảng trắng)
        // để không cắt nhầm class chỉ chứa "missav" bên trong một từ
        // dài hơn không liên quan (vd notmissav_media- phải giữ nguyên).
        // Pattern: tìm class="..." rồi strip prefix bên trong
        return html.replace(/class="([^"]*)"/g, function (fullMatch, classValue) {
            var normalized = classValue.replace(/(^|\s)(?:missav[0-9]*_[a-z0-9]+|missav[0-9]+[a-z0-9]*)-/g, '$1');
            return 'class="' + normalized + '"';
        });
    },
    cleanText: function (text) {
        if (!text) return "";
        return text.replace(/<[^>]*>/g, "")
            .replace(/&amp;/g, "&")
            .replace(/&quot;/g, '"')
            .replace(/&#039;/g, "'")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">")
            .replace(/\s+/g, " ")
            .trim();
    },
    getMeta: function (html, property) {
        var regex = new RegExp('property="' + property + '"\\s+content="([^"]+)"', 'i');
        var match = html.match(regex);
        return match ? match[1] : "";
    },
    getMetaList: function (html, property) {
        var regex = new RegExp('property="' + property + '"\\s+content="([^"]+)"', 'gi');
        var results = [];
        var match;
        while ((match = regex.exec(html)) !== null) {
            results.push(match[1]);
        }
        return results;
    },
    /**
     * Tối ưu hóa việc lấy Preview URL bằng 3 bước Strategy tương tự như lấy link phim
     */
    extractPreviewUrl: function (itemHtml) {
        // Strategy 1: Regex cơ bản từ data-src của thẻ video
        var previewMatch = itemHtml.match(/<video[^>]+data-src="([^"]+)"/);
        var url = previewMatch ? previewMatch[1] : "";
        
        // Strategy 2: Nếu chỉ là UUID (36 ký tự) thì dựng link surrit
        if (url && url.length === 36 && url.match(/^[0-9a-f-]{36}$/i)) {
            return "https://surrit.com/" + url + "/preview.mp4";
        }
        
        // Strategy 3: Deep Scan UUID trong cụm HTML của item (giống Strategy của link phim)
        if (!url || url === "") {
            var uuidMatch = itemHtml.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
            if (uuidMatch) {
                return "https://surrit.com/" + uuidMatch[0] + "/preview.mp4";
            }
        }
        
        // Chuẩn hóa protocol
        if (url && url.indexOf('//') === 0) {
            return "https:" + url;
        }
        
        return url;
    }
};

// =============================================================================
// STREAM UUID EXTRACTION (shared by parseMovieDetail & parseDetailResponse)
// =============================================================================

// Strategy 1 (v1.1.5 repair): pull the UUID out of the eval()-packed word
// list. Measured layout (2026-11-22, live title pages): the five UUID
// segments are stored as [12,4,4,4,8]-char hex pieces in REVERSED
// tail-to-head order — e.g. parts [..., '8863672dd564', '93a8', '4a3f',
// '3863', '4e7443d3', ...] reassemble to 4e7443d3-3863-4a3f-93a8-
// 8863672dd564. The pre-1.1.5 filter (/^[0-9a-f]{8,12}$/) caught only the
// 12- and 8-char end pieces (2 of 5), below the >=5 threshold, so S1
// silently yielded nothing (DIAG-MISSAV-2026-11-22). The matcher below
// accepts the measured reversed run, the legacy forward run
// [8,4,4,4,12], and — as a last resort — the original legacy behaviour
// (first five {8,12}-hex pieces in array order). Anchoring on the
// 12/8-char end pieces keeps random 4-char hex words in the list from
// forming a false run.
function missavEvalUuid(html) {
    var evalMatch = html.match(/eval\(function\(p,a,c,k,e,d\)[\s\S]*?'([^']+)'\.split\('\|'\)/i);
    if (!evalMatch) return "";
    var parts = evalMatch[1].split('|');
    // Confirm it's the video source eval (not some other packed block)
    var hasSurrit = false;
    for (var i = 0; i < parts.length; i++) {
        if (parts[i] === 'surrit' || parts[i] === 'sixyik') { hasSurrit = true; break; }
    }
    if (!hasSurrit) return "";

    var isHex = function (s) { return /^[0-9a-f]+$/.test(s); };
    for (var i = 0; i + 4 < parts.length; i++) {
        var a = parts[i], b = parts[i + 1], c = parts[i + 2], d = parts[i + 3], e = parts[i + 4];
        if (!isHex(a) || !isHex(b) || !isHex(c) || !isHex(d) || !isHex(e)) continue;
        // Legacy forward layout: [8,4,4,4,12] in segment order
        if (a.length === 8 && b.length === 4 && c.length === 4 && d.length === 4 && e.length === 12) {
            return a + '-' + b + '-' + c + '-' + d + '-' + e;
        }
        // Measured layout: [12,4,4,4,8] stored tail-to-head -> reverse
        if (a.length === 12 && b.length === 4 && c.length === 4 && d.length === 4 && e.length === 8) {
            return e + '-' + d + '-' + c + '-' + b + '-' + a;
        }
    }
    // Legacy fallback (pre-2026-11 pages): first five {8,12}-hex pieces
    var uuidParts = [];
    for (var j = 0; j < parts.length; j++) {
        if (/^[0-9a-f]{8,12}$/.test(parts[j])) uuidParts.push(parts[j]);
    }
    if (uuidParts.length >= 5) {
        return uuidParts[0] + '-' + uuidParts[1] + '-' + uuidParts[2] + '-' + uuidParts[3] + '-' + uuidParts[4];
    }
    return "";
}

// Deep-scan candidate ranking (v1.1.5): every distinct UUID in the page,
// best first. The real stream UUID repeats 100+x per page while decoys
// (measured on sister-mirror pages: a second UUID appearing exactly x1)
// sit at the bottom — so frequency is the primary key, replacing the old
// first-match-in-document-order pick, which would take a decoy placed
// earlier in the page. A candidate whose nearby context mentions
// surrit/m3u8 outranks raw frequency ties. The existing blacklist context
// filter still applies. Attempt budget: at most MISSAV_MAX_UUID_CANDIDATES
// distinct candidates (the most frequent ones) get context evaluation —
// measured pages carry <=2 distinct UUIDs and the real one is by
// construction among the most frequent, so 8 bounds worst-case string
// work on ad-heavy pages without ever excluding a plausible candidate.
var MISSAV_MAX_UUID_CANDIDATES = 8;
// v1.1.6 (SPEC-136 §3.2): how many ranked alternates parseDetailResponse
// emits as alternateURLs for the app-layer pre-flight — capped at 4, so
// primary + alternates = at most 5 pre-flight tries.
var MISSAV_MAX_ALTERNATE_URLS = 4;
var MISSAV_UUID_BLACKLIST = ["snaptrckr", "user_uuid", "popunder", "banner", "monitoring", "crypto", "randomUUID", "generateUUID"];

function missavRankedUuids(html) {
    var uuidRegex = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
    var stats = {};
    var order = [];
    var match;
    while ((match = uuidRegex.exec(html)) !== null) {
        var u = match[0].toLowerCase();
        if (!stats[u]) {
            stats[u] = { uuid: u, count: 0, first: match.index, positions: [] };
            order.push(u);
        }
        stats[u].count++;
        if (stats[u].positions.length < 3) stats[u].positions.push(match.index);
    }
    // Frequency first, then document order; cap the evaluated set (budget).
    var ranked = order.map(function (u) { return stats[u]; });
    ranked.sort(function (x, y) {
        if (y.count !== x.count) return y.count - x.count;
        return x.first - y.first;
    });
    if (ranked.length > MISSAV_MAX_UUID_CANDIDATES) {
        ranked = ranked.slice(0, MISSAV_MAX_UUID_CANDIDATES);
    }
    var candidates = [];
    for (var i = 0; i < ranked.length; i++) {
        var s = ranked[i];
        var isBad = false;
        var hasStreamContext = false;
        for (var p = 0; p < s.positions.length; p++) {
            var idx = s.positions[p];
            var context = html.substring(Math.max(0, idx - 120), Math.min(html.length, idx + 120));
            if (p === 0) {
                for (var j = 0; j < MISSAV_UUID_BLACKLIST.length; j++) {
                    if (context.indexOf(MISSAV_UUID_BLACKLIST[j]) !== -1) { isBad = true; break; }
                }
                if (isBad) break;
            }
            if (context.indexOf('surrit') !== -1 || context.indexOf('m3u8') !== -1) {
                hasStreamContext = true;
            }
        }
        if (isBad) continue;
        s.streamContext = hasStreamContext;
        candidates.push(s);
    }
    // Stream-context candidates first; frequency decides inside each tier.
    candidates.sort(function (x, y) {
        if (x.streamContext !== y.streamContext) return x.streamContext ? -1 : 1;
        if (y.count !== x.count) return y.count - x.count;
        return x.first - y.first;
    });
    return candidates;
}

function missavBestUuid(html) {
    var candidates = missavRankedUuids(html);
    return candidates.length ? candidates[0].uuid : "";
}

function parseListResponse(html) {
    // Normalize HTML: strip missav_media- prefix từ CSS class
    html = PluginUtils.normalizeHtml(html);
    var movies = [];

    // SPECIAL CASE: Search page uses Alpine.js + Recombee API (dynamic loading)
    // The search results are loaded via JavaScript, not static HTML
    // We detect this by looking for the Recombee client initialization
    var isSearchPage = html.indexOf('window.recombeeClient.send(new recombee.SearchItems') !== -1 ||
        html.indexOf('x-data="{') !== -1 && html.indexOf('recommendItems') !== -1;

    if (isSearchPage) {
        // Return a helpful message since we can't parse dynamic JS content
        return JSON.stringify({
            items: [{
                id: "/vi",
                title: "⚠️ Tìm kiếm MissAV chưa hỗ trợ",
                posterUrl: "",
                backdropUrl: "",
                description: "Trang tìm kiếm của MissAV sử dụng công nghệ tải động (Alpine.js + Recombee API), không thể parse từ HTML tĩnh. Vui lòng sử dụng các mục 'Thể loại', 'Hôm nay nóng', 'Mới nhất' để duyệt phim.",
                year: 0,
                quality: "INFO",
                episode_current: "",
                lang: ""
            }],
            pagination: {
                currentPage: 1,
                totalPages: 1,
                totalItems: 1,
                itemsPerPage: 1
            }
        });
    }

    // Scenario 1: Genre Grid (e.g. from /vi/genres)
    // Scenario 1.5: Actresses Grid (e.g. from /vi/actresses)

    // DETECT PAGE TYPE
    // 1. Check for Actresses Page first (Priority)
    // Look for multiple links containing '/actresses/'
    var actressLinkMatch = html.match(/href="[^"]*\/actresses\/[^"]+"/g);
    var isActressesPage = (actressLinkMatch && actressLinkMatch.length > 5);

    // 2. Check for Genres Page (if not Actresses)
    var isAllGenresPage = !isActressesPage &&
        html.indexOf('class="text-nord13"') !== -1 &&
        html.indexOf(':đếm video') !== -1;

    if (isActressesPage) {
        // Tactic: Isolate the Grid UL first to avoid header/footer noise (Language flags etc.)
        // The list is usually inside a <ul class="... grid-cols-2 ...">
        var gridMatch = html.match(/<ul[^>]*class="[^"]*grid-cols-2[^"]*"[^>]*>([\s\S]*?)<\/ul>/);
        var searchScope = gridMatch ? gridMatch[1] : html;

        // List of blocked names (Language switcher labels)
        var blockedNames = ["Tiếng Việt", "English", "繁體中文", "简体中文", "日本語", "한국의", "Melayu", "ไทย", "Deutsch", "Français", "Bahasa Indonesia", "Filipino", "Português", "MissAV"];
        var foundActresses = {};

        // Parse each <li> item
        var liRegex = /<li[\s\S]*?<\/li>/gi;
        var match;

        while ((match = liRegex.exec(searchScope)) !== null) {
            var itemHtml = match[0];

            // 1. Identify Actress URL
            // Look for link containing /actresses/ inside this item
            var urlMatch = itemHtml.match(/href="([^"]*\/actresses\/[^"]+)"/);
            if (!urlMatch) continue;

            var url = urlMatch[1];
            // Exclude links with '?' (pagination/language)
            if (url.indexOf('?') !== -1) continue;

            // 2. Extract Name
            // Try to find h4 first (most reliable in this layout)
            var nameMatch = itemHtml.match(/<h4[^>]*>([\s\S]*?)<\/h4>/);
            var nameRaw = nameMatch ? nameMatch[1] : "";

            // Fallback to alt tag on image if h4 missing
            if (!nameRaw) {
                var altMatch = itemHtml.match(/<img[^>]+alt="([^"]+)"/);
                if (altMatch) nameRaw = altMatch[1];
            }

            var name = PluginUtils.cleanText(nameRaw);
            if (!name || name.length < 2) continue;
            if (name.indexOf(':đếm') !== -1) continue;

            // Filter out language names
            var isBlocked = false;
            for (var k = 0; k < blockedNames.length; k++) {
                if (name === blockedNames[k]) { isBlocked = true; break; }
            }
            if (isBlocked) continue;

            // 3. Extract Image
            // Find img tag with src
            var imgMatch = itemHtml.match(/<img[^>]+src="([^"]+)"/);
            var img = imgMatch ? imgMatch[1] : "";

            // Filter flags/icons just in case
            if (img.indexOf('flag') !== -1 || img.indexOf('icon') !== -1) img = "";

            var slug = url.replace(/https?:\/\/[^\/]+/, "");
            if (slug.indexOf("/") !== 0) slug = "/" + slug;

            if (!foundActresses[slug]) {
                movies.push({
                    id: slug,
                    title: name,
                    posterUrl: img,
                    backdropUrl: img,
                    description: "Nữ diễn viên",
                    year: 0,
                    quality: "ACTRESS",
                    episode_current: "",
                    lang: ""
                });
                foundActresses[slug] = true;
            }
        }
    } else if (isAllGenresPage) {
        // GENRE PARSING LOGIC
        var genreRegex = /<a[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi;
        var foundSlugs = {};
        var match;

        while ((match = genreRegex.exec(html)) !== null) {
            var url = match[1];
            var innerContent = match[2];

            // Filter: Must be a genre link and MUST NOT contain the count text in the link itself
            if (url.indexOf('/genres/') !== -1 && innerContent.indexOf(':đếm video') === -1) {
                var name = PluginUtils.cleanText(innerContent);
                if (!name || name.length < 2) continue;

                var slug = url.replace(/https?:\/\/[^\/]+/, "");
                if (slug.indexOf("/") !== 0) slug = "/" + slug;

                // Avoid duplicates
                if (!foundSlugs[slug]) {
                    movies.push({
                        id: slug,
                        title: name,
                        posterUrl: "",
                        backdropUrl: "",
                        description: "Thể loại",
                        year: 0,
                        quality: "CAT",
                        episode_current: "",
                        lang: ""
                    });
                    foundSlugs[slug] = true;
                }
            }
        }
    }

    // Scenario 2: Standard Movie List
    if (movies.length === 0) {
        // More resilient split by searching for partial class name
        var parts = html.split('thumbnail group');
        if (parts.length <= 1) parts = html.split('class="thumbnail'); // Fallback split

        for (var i = 1; i < parts.length; i++) {
            var itemHtml = parts[i];

            // Extract Slug/ID first
            var linkMatch = itemHtml.match(/<a[^>]+href="[^"]*\/vi\/([^"\/ \?]+)"/);
            var slug = linkMatch ? "vi/" + linkMatch[1] : "";

            var fullLinkMatch = itemHtml.match(/<a[^>]+href="([^"]+)"/);
            if (fullLinkMatch) {
                var fullUrl = fullLinkMatch[1];
                slug = fullUrl.replace(/https?:\/\/[^\/]+/, "");
                if (slug.indexOf("/") !== 0) slug = "/" + slug;
            }

            // Extract Code from text-nord13 explicitly
            var codeMatch = itemHtml.match(/class="[^"]*text-nord13[^"]*"[^>]*>([\s\S]*?)<\/a>/);
            var code = codeMatch ? PluginUtils.cleanText(codeMatch[1]) : "";

            // Fallback for code: extract from slug (e.g., /vi/snos-056 -> snos-056)
            if (!code && slug) {
                var slugParts = slug.split("/");
                code = slugParts[slugParts.length - 1];
            }

            // Extract Candidates for Title
            var titleCandidates = [];
            // 1. Look for alt/title in img tag (best source)
            var imgFullMatch = itemHtml.match(/<img[^>]+(?:alt|title)="([^"]+)"/i);
            if (imgFullMatch) titleCandidates.push(PluginUtils.cleanText(imgFullMatch[1]));

            // 2. Look for any other title attributes
            var otherTitleRegex = /title="([^"]+)"/gi;
            var tMatch;
            while ((tMatch = otherTitleRegex.exec(itemHtml)) !== null) {
                var val = PluginUtils.cleanText(tMatch[1]);
                if (val.toUpperCase() !== code.toUpperCase()) {
                    titleCandidates.push(val);
                }
            }

            // Choose the longest candidate
            var bestTitle = "";
            for (var c = 0; c < titleCandidates.length; c++) {
                if (titleCandidates[c].length > bestTitle.length) {
                    bestTitle = titleCandidates[c];
                }
            }

            // Clean bestTitle: remove code if it prefixes the title
            var cleanTitle = bestTitle || code;
            if (code && cleanTitle.toUpperCase().indexOf(code.toUpperCase()) === 0) {
                var stripped = cleanTitle.substring(code.length).trim();
                if (stripped.indexOf("-") === 0 || stripped.indexOf(" ") === 0) {
                    stripped = stripped.substring(1).trim();
                }
                if (stripped.length > 3) {
                    cleanTitle = stripped;
                }
            }

            if (!cleanTitle) cleanTitle = code || "No Title";

            // Extract Thumbnail
            var thumbMatch = itemHtml.match(/<img[\s\S]*?data-src="([^"]+)"/) ||
                itemHtml.match(/<img[\s\S]*?src="([^"]+)"/);
            var thumb = thumbMatch ? thumbMatch[1] : "";

            // Upgrade thumbnail to cover
            if (thumb && thumb.indexOf("cover-t.jpg") !== -1) {
                thumb = thumb.replace("/cover-t.jpg", "/cover.jpg");
            }

            if (slug && !slug.includes("actresses") && !slug.includes("genres")) {
                // FILTER: Discard template items (junk data often found at the end of search/lists)
                if (slug.indexOf('item.') !== -1 || slug.indexOf('{{') !== -1 || slug === "/" || slug === "#") continue;
                if (cleanTitle.indexOf('item.') !== -1 || cleanTitle.indexOf('{{') !== -1) continue;
                if (thumb.indexOf('item.') !== -1 || thumb.indexOf('itemUrl') !== -1) continue;

                // Try to extract Year/Duration if available
                var durationMatch = itemHtml.match(/<span[^>]*>\s*(\d+):(\d+):(\d+)\s*<\/span>/);
                var duration = durationMatch ? durationMatch[1] + ":" + durationMatch[2] + ":" + durationMatch[3] : "";

                // Check for "Không kiểm duyệt" (Uncensored) badge
                var isUncensored = itemHtml.indexOf("Không kiểm duyệt") !== -1 ||
                    itemHtml.indexOf("Uncensored") !== -1 ||
                    itemHtml.indexOf("bg-blue-800") !== -1;

                // Extract Preview Video bằng Strategy tối ưu
                var previewUrl = PluginUtils.extractPreviewUrl(itemHtml);

                movies.push({
                    id: slug,
                    title: cleanTitle,
                    posterUrl: thumb,
                    backdropUrl: thumb,
                    description: duration,
                    year: 0,
                    quality: isUncensored ? "K.K.Duyệt" : "HD",
                    episode_current: isUncensored ? "K.K.Duyệt" : "Full",
                    lang: code, // Show only the code below the title
                    previewUrl: previewUrl
                });
            }
        }
    }

    // Pagination
    var totalPages = 1;
    var currentPage = 1;

    // Parse current page: <span class="bg-nord8 ...">2</span> or similar active class
    var currentMatch = html.match(/<span[^>]+class="[^"]*(?:bg-nord8|active|current)[^"]*"[^>]*>\s*(\d+)\s*<\/span>/i) ||
        html.match(/<a[^>]+class="[^"]*(?:bg-nord8|active|current)[^"]*"[^>]*>\s*(\d+)\s*<\/a>/i);

    if (currentMatch) {
        currentPage = parseInt(currentMatch[1]);
    }

    // Capture all page numbers and find max
    var allPageNums = html.match(/page=(\d+)/g);
    if (allPageNums) {
        for (var j = 0; j < allPageNums.length; j++) {
            var p = parseInt(allPageNums[j].match(/\d+/)[0]);
            if (p > totalPages) totalPages = p;
        }
    }

    // Also check input field pagination value (if any)
    var inputPageMatch = html.match(/name="page" value="(\d+)"/) || html.match(/type="number" value="(\d+)"/);
    if (inputPageMatch) {
        var pVal = parseInt(inputPageMatch[1]);
        if (pVal > 0) currentPage = Math.max(currentPage, pVal);
    }

    // Total pages usually appears after a slash or in a last-page link or in the last numeric link before "Next"
    var totalLabelMatch = html.match(/\/ (\d+)\s*<\/span>/) ||
        html.match(/>(\d+)<\/a>\s*<a[^>]*aria-label="Next"/i) ||
        html.match(/page=(\d+)[^>]*aria-label="Last"/i);

    if (totalLabelMatch) {
        var tVal = parseInt(totalLabelMatch[1]);
        if (tVal > 0) totalPages = Math.max(totalPages, tVal);
    }

    // Fallback: If we have many page=N links, find the maximum N mentioned
    if (totalPages === 1 && allPageNums) {
        // allPageNums was already captured above
        for (var k = 0; k < allPageNums.length; k++) {
            var p = parseInt(allPageNums[k].match(/\d+/)[0]);
            if (p > totalPages) totalPages = p;
        }
    }

    return JSON.stringify({
        items: movies,
        pagination: {
            currentPage: currentPage,
            totalPages: totalPages || 1,
            totalItems: movies.length,
            itemsPerPage: 20
        }
    });
}

function parseSearchResponse(html) {
    return parseListResponse(html);
}

function parseMovieDetail(html, pageUrl) {
    // Normalize HTML: strip missav_media- prefix từ CSS class
    html = PluginUtils.normalizeHtml(html);
    try {
        // Helper to extract relative slug from full URL
        var getSlug = function (url) {
            if (!url) return "";
            return url.replace(/^https?:\/\/[^\/]+/, "");
        };

        // 1. Helper for specific HTML structure: 
        // <div class="text-secondary"><span>Label:</span> <tag>Value</tag></div>
        var getField = function (labelKey) {
            // Capture entire content between </span> and </div> (across newlines)
            var regex = new RegExp("<span>" + labelKey + ":<\\/span>([\\s\\S]*?)<\\/div>", "i");
            var match = html.match(regex);
            if (!match) return "";

            var content = match[1];
            // Check for link
            var linkMatch = content.match(/<a[^>]+href="([^"]+)"[^>]*>([^<]+)<\/a>/i);
            if (linkMatch) {
                var url = linkMatch[1];
                var text = PluginUtils.cleanText(linkMatch[2]);
                return "[" + text + "](" + getSlug(url) + ")";
            }
            // Check for <time> tag (e.g. release date)
            var timeMatch = content.match(/<time[^>]*>([^<]+)<\/time>/i);
            if (timeMatch) {
                return PluginUtils.cleanText(timeMatch[1]);
            }
            // Check for <span class="font-medium"> (e.g. code, title)
            var spanMatch = content.match(/<span[^>]*>([^<]+)<\/span>/i);
            if (spanMatch) {
                return PluginUtils.cleanText(spanMatch[1]);
            }
            // Fallback to text (strip all tags)
            return PluginUtils.cleanText(content.replace(/<[^>]+>/g, ""));
        };

        var getMultiField = function (labelKey) {
            // Find start: <span>Label:</span>
            var regexStart = new RegExp("<span>" + labelKey + ":<\\/span>", "i");
            var matchStart = html.match(regexStart);
            if (!matchStart) return "";

            // Look ahead for closing div of the text-secondary container
            var startIndex = matchStart.index + matchStart[0].length;
            var searchArea = html.substring(startIndex);
            var divEnd = searchArea.indexOf("</div>");
            if (divEnd === -1) divEnd = searchArea.length;

            var content = searchArea.substring(0, divEnd);

            // Extract all links: [Name](Slug)
            var items = [];
            var linkRegex = /<a[^>]+href="([^"]+)"[^>]*>([^<]+)<\/a>/g;
            var linkMatch;
            while ((linkMatch = linkRegex.exec(content)) !== null) {
                var url = linkMatch[1];
                var text = PluginUtils.cleanText(linkMatch[2]);
                if (text && !text.includes("<img")) {
                    items.push("[" + text + "](" + getSlug(url) + ")");
                }
            }
            return items.join(", ");
        };

        // v1.1.7 (L-20): plain-at-extraction variants for the
        // fields the app renders VERBATIM (director ->
        // MovieDetail.director, genres ->
        // MovieDetail.category). getField/getMultiField
        // manufacture the "[text](route)" markdown from link
        // text and route that are still SEPARATE values at
        // extraction time; these variants return the cleaned
        // link text directly, per item, instead of encoding
        // to markdown and parsing it back. By construction a
        // name containing square brackets survives byte-exact,
        // a route containing ")" cannot corrupt the text, and
        // an empty/whitespace anchor yields an empty
        // contribution (skipped in multi-field joins; the
        // single field falls back to "") — no "[](/route)"
        // can ever be synthesised on the plain paths. Casts
        // keep getMultiField unchanged: the app parses the
        // [Name](route) convention back into routes.
        var getPlainField = function (labelKey) {
            // Same field-block scan as getField; only the
            // linked branch differs (returns the text itself).
            var regex = new RegExp("<span>" + labelKey + ":<\\/span>([\\s\\S]*?)<\\/div>", "i");
            var match = html.match(regex);
            if (!match) return "";

            var content = match[1];
            // Linked value: the cleaned link text IS the value.
            var linkMatch = content.match(/<a[^>]+href="([^"]+)"[^>]*>([^<]+)<\/a>/i);
            if (linkMatch) {
                return PluginUtils.cleanText(linkMatch[2]);
            }
            // Check for <time> tag (e.g. release date)
            var timeMatch = content.match(/<time[^>]*>([^<]+)<\/time>/i);
            if (timeMatch) {
                return PluginUtils.cleanText(timeMatch[1]);
            }
            // Check for <span class="font-medium"> (e.g. code, title)
            var spanMatch = content.match(/<span[^>]*>([^<]+)<\/span>/i);
            if (spanMatch) {
                return PluginUtils.cleanText(spanMatch[1]);
            }
            // Fallback to text (strip all tags)
            return PluginUtils.cleanText(content.replace(/<[^>]+>/g, ""));
        };

        var getPlainMultiField = function (labelKey) {
            // Same field-block scan as getMultiField; items
            // collect the cleaned link text, never markdown.
            var regexStart = new RegExp("<span>" + labelKey + ":<\\/span>", "i");
            var matchStart = html.match(regexStart);
            if (!matchStart) return "";

            // Look ahead for closing div of the text-secondary container
            var startIndex = matchStart.index + matchStart[0].length;
            var searchArea = html.substring(startIndex);
            var divEnd = searchArea.indexOf("</div>");
            if (divEnd === -1) divEnd = searchArea.length;

            var content = searchArea.substring(0, divEnd);

            // Extract all links: plain text per item; an empty
            // anchor contributes nothing and is skipped.
            var items = [];
            var linkRegex = /<a[^>]+href="([^"]+)"[^>]*>([^<]+)<\/a>/g;
            var linkMatch;
            while ((linkMatch = linkRegex.exec(content)) !== null) {
                var text = PluginUtils.cleanText(linkMatch[2]);
                if (text && !text.includes("<img")) {
                    items.push(text);
                }
            }
            return items.join(", ");
        };

        // 2. Extract Metadata
        var code = getField("Mã số") || getField("Code");
        var releaseDate = getField("Ngày phát hành") || getField("Release date");
        var studio = getField("nhà sản xuất") || getField("Maker");
        var director = getPlainField("Giám đốc") || getPlainField("Director");
        var label = getField("Nhãn") || getField("Label");

        var casts = getMultiField("Nữ diễn viên") || getMultiField("Actresses");
        var genres = getPlainMultiField("thể loại") || getPlainMultiField("Genre") || getPlainMultiField("Genres");
        var series = getMultiField("Loạt") || getMultiField("Series");

        // 3. Fallback/Original Metadata (if above fails)
        if (!code) {
            var dvdIdMatch = html.match(/dvdId:\s*'([^']+)'/);
            code = dvdIdMatch ? dvdIdMatch[1] : "";
        }

        var title = PluginUtils.getMeta(html, "og:title");
        var thumb = PluginUtils.getMeta(html, "og:image");
        var desc = PluginUtils.getMeta(html, "og:description");

        var previewMatch = html.match(/<video[^>]+data-src="([^"]+)"/) || html.match(/video_url:\s*'([^']+)'/);
        var previewUrl = previewMatch ? previewMatch[1] : "";

        // Alternative: derive from thumb if it's a cover.jpg
        if (!previewUrl && thumb && thumb.indexOf("cover.jpg") !== -1) {
            previewUrl = thumb.replace("cover.jpg", "preview.mp4");
        }

        // Prepare a Display Title that includes the code in brackets for clarity in Details
        var displayTitle = title;
        // Strip code if it's already there to re-add in a standardized way [CODE] Title
        if (code && displayTitle.toUpperCase().indexOf(code.toUpperCase()) === 0) {
            displayTitle = displayTitle.substring(code.length).trim();
            if (displayTitle.indexOf("-") === 0 || displayTitle.indexOf(" ") === 0) {
                displayTitle = displayTitle.substring(1).trim();
            }
        }

        if (code) {
            displayTitle = "[" + code.toUpperCase() + "] " + displayTitle;
        }

        // Truncate Title if extremely long
        var titleWords = displayTitle.split(" ");
        if (titleWords.length > 25) {
            displayTitle = titleWords.slice(0, 25).join(" ") + "...";
        }

        // 4. Stream URL Logic
        var streamUrl = "";
        var uuid = "";

        // Strategy 1: Extract from eval() obfuscated code
        // The source URL is hidden inside eval(function(p,a,c,k,e,d){...});
        // the fragment layout is handled by missavEvalUuid (v1.1.5 repair —
        // the packed pieces are now stored reversed, [12,4,4,4,8]).
        uuid = missavEvalUuid(html);

        // Strategy 2: Check for direct Surrit/Sixyik/Nineyu/Fourhoi patterns
        if (!uuid) {
            var surritMatch = html.match(/surrit\.com\/([0-9a-f-]{36})/i) ||
                html.match(/sixyik\.com\/([0-9a-f-]{36})/i) ||
                html.match(/nineyu\.com\/([0-9a-f-]{36})/i) ||
                html.match(/fourhoi\.com\/([0-9a-f-]{36})/i);
            if (surritMatch) {
                uuid = surritMatch[1];
            }
        }

        // Strategy 3: Check for blob/data-source patterns
        if (!uuid && !streamUrl) {
            var blobMatch = html.match(/src=["']blob:[^"']+\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})["']/i);
            var sourceMatch = html.match(/data-source=["']([^"']+)["']/i);
            if (blobMatch) {
                uuid = blobMatch[1];
            } else if (sourceMatch && sourceMatch[1].indexOf('m3u8') !== -1) {
                streamUrl = sourceMatch[1];
            }
        }

        // Strategy 4: Deep Scan for UUID (fallback) — v1.1.5: frequency-
        // ranked candidates via missavBestUuid (a decoy UUID appearing
        // once can no longer beat the real one by sitting earlier in
        // the page).
        if (!uuid && !streamUrl) {
            uuid = missavBestUuid(html);
        }

        if (uuid) {
            streamUrl = "https://surrit.com/" + uuid + "/playlist.m3u8";
        }

        var servers = [];
        if (streamUrl) {
            // IMPORTANT: Dùng URL gốc thay vì m3u8 URL trực tiếp
            // Để PlayerViewModel gọi getStreamLink() → headers Referer được gắn
            // surrit.com yêu cầu Referer header, nếu gọi trực tiếp sẽ bị 403
            var episodeId = pageUrl || streamUrl;
            servers.push({
                name: "Stream",
                episodes: [{
                    id: episodeId,
                    name: "Full",
                    slug: "full"
                }]
            });
        }

        // 5. Construct Result
        // Composite status field to show Studio and Label
        var statusLine = "";
        if (studio) statusLine += "Studio: " + studio;
        if (label) statusLine += (statusLine ? " | " : "") + "Label: " + label;
        if (!statusLine && releaseDate) statusLine = "Released: " + releaseDate;

        var year = releaseDate ? parseInt(releaseDate.substring(0, 4)) : 0;

        return JSON.stringify({
            id: code || "",
            title: PluginUtils.cleanText(displayTitle),
            posterUrl: thumb,
            backdropUrl: thumb,
            description: PluginUtils.cleanText(desc),
            servers: servers,
            quality: "HD",
            lang: "Vietsub",
            year: year,
            rating: 0,
            casts: casts,
            director: director,
            category: genres,
            status: statusLine,
            duration: series ? "Series: " + series : "", // Or parse duration if needed
            previewUrl: previewUrl || ""
        });
    } catch (e) {
        return "null";
    }
}

function parseDetailResponse(html) {
    // Extract UUID directly from HTML (independent from parseMovieDetail)
    var uuid = "";
    var streamUrl = "";

    // Strategy 1: Decode eval() obfuscated code (v1.1.5 repair — shared
    // helper, reversed [12,4,4,4,8] fragment layout)
    uuid = missavEvalUuid(html);

    // Strategy 2: Direct domain scan
    if (!uuid) {
        var m = html.match(/surrit\.com\/([0-9a-f-]{36})/i) ||
            html.match(/sixyik\.com\/([0-9a-f-]{36})/i) ||
            html.match(/nineyu\.com\/([0-9a-f-]{36})/i) ||
            html.match(/fourhoi\.com\/([0-9a-f-]{36})/i);
        if (m) uuid = m[1];
    }

    // Strategy 3: Deep UUID scan (fallback) — v1.1.5: frequency-ranked
    // candidates via missavBestUuid (decoy-proof; see helper).
    if (!uuid) {
        uuid = missavBestUuid(html);
    }

    if (uuid) {
        streamUrl = "https://surrit.com/" + uuid + "/playlist.m3u8";
    }

    // v1.1.6 (SPEC-136 §3.2): ranked alternate candidates for the
    // app-layer pre-flight. When the primary's playlist is refused, the
    // app walks [url] + alternateURLs in order; the alternates are the
    // other plausible stream UUIDs on the page, in missavRankedUuids
    // order, the primary itself excluded, capped at
    // MISSAV_MAX_ALTERNATE_URLS. Every candidate is a surrit playlist
    // URL and shares this response's headers object — the app sends
    // the same headers for primary and alternates alike. The list is
    // present but empty when extraction found a single candidate, and
    // also empty on the failure shape below (no candidate survived).
    var alternateURLs = [];
    if (uuid) {
        var rankedForAlternates = missavRankedUuids(html);
        for (var ai = 0; ai < rankedForAlternates.length && alternateURLs.length < MISSAV_MAX_ALTERNATE_URLS; ai++) {
            var candUuid = rankedForAlternates[ai].uuid;
            if (candUuid === uuid.toLowerCase()) continue;
            alternateURLs.push("https://surrit.com/" + candUuid + "/playlist.m3u8");
        }
    }

    // Failure shape (unchanged contract): when no candidate survives,
    // url stays "" — the shared resolve-failure signal across the
    // plugin set is the EMPTY URL (the exact JSON shape differs per
    // plugin — vlxx adds isEmbed/headers, njav's bare fallback is
    // {"url":""} — but StreamInfo's defaulting decoder makes them
    // app-equivalent). The app reads an empty url
    // as "no playable link" and surfaces its error state instead of
    // handing the player an unresolvable address. NOTE: a UUID that
    // extracts cleanly but whose playlist the source refuses
    // (403/BucketPunish) cannot be detected here — the plugin contract
    // gives plugins no fetch capability, so that pre-flight belongs to
    // the app layer (RESEARCH-MISSAV R2); since v1.1.6 the ranked
    // candidate order such a pre-flight should try crosses the bridge
    // as alternateURLs above (SPEC-136 §3.2).
    return JSON.stringify({
        url: streamUrl,
        headers: {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Referer": "https://missav123.com/",
            "Origin": "https://missav123.com"
        },
        subtitles: [],
        alternateURLs: alternateURLs
    });
}

function parseCategoriesResponse(html) {
    // Normalize HTML: strip missav_media- prefix từ CSS class
    html = PluginUtils.normalizeHtml(html);
    var categories = [];

    // Add "All Genres" as the first item
    categories.push({ name: "Tất cả thể loại", slug: "vi/genres" });

    // Regex to capture both relative and absolute links: href=".../vi/genres/slug"
    // Capture group 1: potentially full url or relative path
    // Capture group 2: Category Name
    var regex = /<a[^>]+href="([^"]*\/vi\/genres\/[^"]+)"[^>]*>([^<]+)<\/a>/g;
    var match;
    var seen = {};

    while ((match = regex.exec(html)) !== null) {
        var fullPath = match[1];
        var name = PluginUtils.cleanText(match[2]);

        // Extract slug from path (e.g. /vi/genres/vr -> vr)
        var parts = fullPath.split("/genres/");
        var slug = parts.length > 1 ? parts[1] : "";

        if (slug && name && !seen[slug]) {
            seen[slug] = true;
            // Ensure slug is full relative path for plugin system
            categories.push({ name: name, slug: "vi/genres/" + slug });
        }
    }
    return JSON.stringify(categories);
}

function parseCountriesResponse(html) { return "[]"; }
function parseYearsResponse(html) { return "[]"; }
