// =============================================================================
// CONFIGURATION & METADATA
// =============================================================================

function getManifest() {
    return JSON.stringify({
        "id": "123av",
        "name": "123AV",
        "version": "1.0.8",
        "baseUrl": "https://123av.com",
        "referrer": "https://123av.com/",
        "iconUrl": "https://123av.com/assets/123av/favicon.png",
        "isEnabled": true,
        "isAdult": true,
        "type": "VIDEO",
        "layoutType": "HORIZONTAL",
        "subtitleCat": false
    });
}

function getHomeSections() {
    return JSON.stringify([
        { slug: 'en/new', title: 'Mới Cập Nhật', type: 'Horizontal', path: '' },
        { slug: 'en/hot', title: 'Hot & Thịnh Hành', type: 'Horizontal', path: '' },
        { slug: 'en/censored', title: 'Phim Có Che (Censored)', type: 'Horizontal', path: '' },
        { slug: 'en/uncensored', title: 'Không Che (Uncensored)', type: 'Horizontal', path: '' },
        { slug: 'en/uncensored-leaked', title: 'Không Che Rò Rỉ (Leaked)', type: 'Horizontal', path: '' }
    ]);
}

function getPrimaryCategories() {
    return JSON.stringify([
        { name: 'Mới cập nhật', slug: 'en/new' },
        { name: 'Thịnh hành', slug: 'en/hot' },
        { name: 'Có che (Censored)', slug: 'en/censored' },
        { name: 'Không che (Uncensored)', slug: 'en/uncensored' },
        { name: 'Không che rò rỉ', slug: 'en/uncensored-leaked' },
        { name: 'Thể loại', slug: 'en/genres' },
        { name: 'Diễn viên', slug: 'en/actresses' },
        { name: 'Nhà sản xuất', slug: 'en/makers' },
        { name: 'Loạt phim (Series)', slug: 'en/series' }
    ]);
}

function getFilterConfig() {
    return JSON.stringify({
        sort: [
            { name: 'Mới nhất', value: 'new' },
            { name: 'Hôm nay', value: 'today' },
            { name: 'Tuần này', value: 'week' },
            { name: 'Tháng này', value: 'month' }
        ],
        category: [
            { name: "Tất cả thể loại", value: "en/genres" },
            { name: "Có che (Censored)", value: "en/censored" },
            { name: "Không che (Uncensored)", value: "en/uncensored" },
            { name: "Không che rò rỉ", value: "en/uncensored-leaked" },
            { name: "Nữ diễn viên", value: "en/actresses" },
            { name: "Nhà sản xuất", value: "en/makers" },
            { name: "Loạt phim (Series)", value: "en/series" }
        ]
    });
}

// =============================================================================
// URL GENERATION
// =============================================================================

function getUrlList(slug, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    var baseUrl = "https://123av.com";
    
    var path = slug || "en/new";
    
    // Ensure path has /en/ prefix
    if (path.indexOf("en/") !== 0 && path.indexOf("/en/") !== 0) {
        if (path.indexOf("/") === 0) path = "en" + path;
        else path = "en/" + path;
    }
    
    if (path.indexOf("/") !== 0) path = "/" + path;
    
    var url = baseUrl + path;
    
    // If slug is a specific page query
    if (url.indexOf("?") !== -1) {
        url += "&page=" + page;
    } else {
        url += "?page=" + page;
    }
    
    // Add sorting filter
    if (filters.sort && filters.sort !== 'new') {
        url += "&sort=" + filters.sort;
    }

    return relayWrap123av(url, "desk", "https://123av.com/");
}

function getUrlSearch(keyword, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    return relayWrap123av("https://123av.com/en/search?keyword=" + encodeURIComponent(keyword) + "&page=" + page, "desk", "https://123av.com/");
}

function getUrlDetail(slug) {
    var url;
    if (slug.indexOf("http") === 0) url = slug;
    else if (slug.indexOf("en/v/") === 0) url = "https://123av.com/" + slug;
    else if (slug.indexOf("/en/v/") === 0) url = "https://123av.com" + slug;
    else if (slug.indexOf("v/") === 0) url = "https://123av.com/en/" + slug;
    else if (slug.indexOf("/v/") === 0) url = "https://123av.com/en" + slug;
    else url = "https://123av.com/en/v/" + slug;
    return relayWrap123av(url, "desk", "https://123av.com/");
}

function getUrlCategories() { return relayWrap123av("https://123av.com/en/genres", "desk", "https://123av.com/"); }
function getUrlCountries() { return ""; }
function getUrlYears() { return ""; }

// =============================================================================
// PARSERS
// =============================================================================

var PluginUtils = {
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
        var regex1 = new RegExp('(?:property|name)=["\']' + property + '["\'][^>]*content=(["\'])(.*?)\\1', 'i');
        var regex2 = new RegExp('content=(["\'])(.*?)\\1[^>]*(?:property|name)=["\']' + property + '["\']', 'i');
        var match = html.match(regex1) || html.match(regex2);
        return match ? match[2] : "";
    },
    decodePlayerJson: function (escapedStr) {
        try {
            var cleanStr = escapedStr.replace(/\\u([0-9a-fA-F]{4})/g, function (match, grp) {
                return String.fromCharCode(parseInt(grp, 16));
            }).replace(/\\/g, '');
            return JSON.parse(cleanStr);
        } catch (e) {
            return [];
        }
    }
};

function parseListResponse(html) {
    var movies = [];
    
    // Check if it's the Actresses list page.
    // A single-actress filmography page also carries >10 actress links
    // (related-actress rail) plus the word 'Actresses', so the link count
    // alone misclassifies it as the index (Phase 0: Nagi Hikaru page has
    // 11 actress hrefs but 24 real film links). The true index carries
    // NO film cards at all, so film cards present => movie branch wins.
    var actressLinkMatch = html.match(/href="[^"]*\/actresses\/[^"]+"/g);
    var filmLinkMatch = html.match(/href="[^"]*\/v\/[^"]+"/g);
    var hasFilmCards = !!(filmLinkMatch && filmLinkMatch.length >= 5);
    var isActressesPage = (actressLinkMatch && actressLinkMatch.length > 10 && html.indexOf('Actresses') !== -1 && !hasFilmCards);
    
    // Check if it's the Genres list page
    var isAllGenresPage = (html.indexOf('/en/genres/') !== -1 && html.indexOf('Genres') !== -1 && html.indexOf('title="Genres"') === -1);
    
    if (isActressesPage) {
        var actressRegex = /<a[^>]+href="([^"]*\/actresses\/([^"\/]+))"[^>]*>([\s\S]*?)<\/a>/gi;
        var foundActresses = {};
        var match;
        
        while ((match = actressRegex.exec(html)) !== null) {
            var url = match[1];
            var slug = "en/actresses/" + match[2];
            var name = PluginUtils.cleanText(match[3]);
            if (!name || name.length < 2 || name.match(/^\d+/) || name.indexOf('.') !== -1) continue;
            
            if (!foundActresses[slug]) {
                movies.push({
                    id: slug,
                    title: name,
                    posterUrl: "",
                    backdropUrl: "",
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
        var genreRegex = /<a[^>]+href="([^"]*\/genres\/([^"\/]+))"[^>]*>([\s\S]*?)<\/a>/gi;
        var foundGenres = {};
        var match;
        
        while ((match = genreRegex.exec(html)) !== null) {
            var url = match[1];
            var slug = "en/genres/" + match[2];
            var name = PluginUtils.cleanText(match[3]).replace(/\d+,\d+|\d+/g, '').trim(); // Remove post count like 170,552
            if (!name || name.length < 2) continue;
            
            if (!foundGenres[slug]) {
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
                foundGenres[slug] = true;
            }
        }
        
    } else {
        // Standard Movie List
        var parts = html.split('class="card"');
        if (parts.length <= 1) {
            parts = html.split('class="featured"');
        }
        
        for (var i = 1; i < parts.length; i++) {
            var cardHtml = parts[i];
            
            var linkMatch = cardHtml.match(/href="([^"]*\/v\/([^"\/]+))"/i);
            if (!linkMatch) continue;
            var rawUrl = linkMatch[1];
            var slug = "en/v/" + linkMatch[2];
            
            var title = "";
            var titleMatch = cardHtml.match(/<h[23][^>]*>([\s\S]*?)<\/h[23]>/i);
            if (titleMatch) {
                title = titleMatch[1].replace(/<[^>]*>/g, "").trim();
            } else {
                var altMatch = cardHtml.match(/<img[^>]+alt="([^"]+)"/i);
                if (altMatch) title = altMatch[1].trim();
            }
            if (!title) title = linkMatch[2];
            
            var imgMatch = cardHtml.match(/<img[^>]+(?:src|data-src)="([^"]+)"/i);
            var poster = imgMatch ? imgMatch[1] : "";
            if (poster && poster.indexOf("//") === 0) poster = "https:" + poster;
            
            var durMatch = cardHtml.match(/class="(?:featured__dur|card__dur)"[^>]*>([^<]+)/i);
            var duration = durMatch ? durMatch[1].trim() : "";
            
            movies.push({
                id: slug,
                title: PluginUtils.cleanText(title),
                posterUrl: poster,
                backdropUrl: poster,
                description: duration ? "Thời lượng: " + duration : "",
                year: 0,
                quality: "HD",
                episode_current: duration,
                lang: "Censored"
            });
        }
    }
    
    // Pagination parse
    var currentPage = 1;
    var totalPages = 1;
    
    var activePageMatch = html.match(/class="[^"]*active[^"]*"[^>]*>(\d+)<\/span>/i) || 
                          html.match(/class="[^"]*active[^"]*"[^>]*>(\d+)<\/a>/i);
    if (activePageMatch) currentPage = parseInt(activePageMatch[1]);
    
    var pageLinks = html.match(/page=(\d+)/g);
    if (pageLinks) {
        for (var p = 0; p < pageLinks.length; p++) {
            var num = parseInt(pageLinks[p].match(/\d+/)[0]);
            if (num > totalPages) totalPages = num;
        }
    }
    
    return JSON.stringify({
        items: movies,
        pagination: {
            currentPage: currentPage,
            totalPages: Math.max(totalPages, currentPage),
            totalItems: movies.length,
            itemsPerPage: 20
        }
    });
}

function parseSearchResponse(html) {
    return parseListResponse(html);
}

function parseMovieDetail(htmlContent) {
    try {
        var title = PluginUtils.getMeta(htmlContent, "og:title") || "";
        var thumb = PluginUtils.getMeta(htmlContent, "og:image") || "";
        var desc = PluginUtils.getMeta(htmlContent, "og:description") || "";
        
        // Trích xuất ảnh bìa phim thật (cover.jpg) từ background-image của player
        var coverMatch = htmlContent.match(/style="background-image:url\(['"]?([^'")]+cover\.jpg[^'")]+)['"]?\)"/i) ||
                         htmlContent.match(/background-image:url\(['"]?([^'")]+cover\.jpg[^'")]+)['"]?\)/i) ||
                         htmlContent.match(/src="([^"]+cover\.jpg[^"]*)"/i);
        if (coverMatch) {
            thumb = coverMatch[1];
        } else if (thumb.indexOf("logo-square.png") !== -1 || thumb.indexOf("logo") !== -1) {
            // Tìm kiếm URL ảnh cover bất kỳ
            var coverGenericMatch = htmlContent.match(/https?:\/\/[^\s"'><]+?\/cover\.jpg[^\s"'><]*/i);
            if (coverGenericMatch) {
                thumb = coverGenericMatch[0];
            }
        }
        
        // Extract release year from release date
        var releaseMatch = htmlContent.match(/<dt>Release date<\/dt>\s*<dd>([^<]+)<\/dd>/i);
        var year = 0;
        if (releaseMatch) {
            var yr = parseInt(releaseMatch[1].substring(0, 4));
            if (yr) year = yr;
        }
        
        // Extract actors — keep the actress slug the page already gives
        // us and emit the shared markdown convention [name](actresses/<slug>)
        // (same form missav uses), so a cast tap can route to the actress's
        // filmography instead of a bare name.
        var actors = [];
        var seenActorSlugs = {};
        var actorPattern = /href="[^"]*\/actresses\/([^"\/]+)">([^<]+)<\/a>/gi;
        var match;
        while ((match = actorPattern.exec(htmlContent)) !== null) {
            var aSlug = match[1];
            var aName = PluginUtils.cleanText(match[2]);
            if (aName && !seenActorSlugs[aSlug]) {
                seenActorSlugs[aSlug] = true;
                actors.push("[" + aName + "](actresses/" + aSlug + ")");
            }
        }
        
        // Extract genres
        var genres = [];
        var genrePattern = /href="[^"]*\/genres\/[^"]+">([^<]+)<\/a>/gi;
        while ((match = genrePattern.exec(htmlContent)) !== null) {
            var gName = PluginUtils.cleanText(match[1]);
            if (gName && genres.indexOf(gName) === -1) genres.push(gName);
        }
        
        // Extract director
        var director = "";
        var dirMatch = htmlContent.match(/<dt>Maker<\/dt>\s*<dd>[\s\S]*?href="[^"]*">([^<]+)<\/a>/i);
        if (dirMatch) director = PluginUtils.cleanText(dirMatch[1]);
        
        // Extract streaming player JSON URL
        var servers = [];
        var playerJsonMatch = /player\(\s*JSON\.parse\(\s*['"]([^'"]+)['"]\s*\)/i.exec(htmlContent);
        
        if (playerJsonMatch) {
            var playerItems = PluginUtils.decodePlayerJson(playerJsonMatch[1]);
            var episodes = [];
            for (var i = 0; i < playerItems.length; i++) {
                var item = playerItems[i];
                var rawUrl = item.url;
                
                episodes.push({
                    id: rawUrl,
                    name: "Server HD #" + (item.name || (i + 1)),
                    slug: "server-" + (i + 1)
                });
            }
            if (episodes.length > 0) {
                servers.push({
                    name: "123AV Play",
                    episodes: episodes
                });
            }
        }
        
        var slug = "";
        var canonicalMatch = htmlContent.match(/<link\s+rel="canonical"\s+href="https:\/\/123av\.com\/[^"\/]+\/v\/([^"]+)"/i);
        if (canonicalMatch) slug = canonicalMatch[1];
        
        return JSON.stringify({
            id: slug,
            title: PluginUtils.cleanText(title),
            posterUrl: thumb,
            backdropUrl: thumb,
            description: PluginUtils.cleanText(desc),
            year: year,
            rating: 0,
            quality: "HD",
            servers: servers,
            episode_current: servers.length > 0 ? "Full" : "No Source",
            lang: "Censored",
            category: genres.join(", "),
            country: "Japan",
            director: director,
            casts: actors.join(", ")
        });
        
    } catch (e) {
        return "null";
    }
}

// =============================================================================
// RESOLVE — Phase 3 rescue (JTV-TVOS-PHASE1-SPIKE-123AV.md §5, spike-proven)
// =============================================================================
// The embed page is a static shell whose only job is to run one module
// script. That script's entire resolve logic, ported here as text parsing:
// extract the id via /e/([a-z0-9_]+)/i, GET <embed-origin>/stream?id=<id>
// (1.0.8 fix: embed ids are MIXED case — 8W30XN, KLKXQV — and the
// pre-1.0.8 pattern had no /i flag, so it truncated 8W30XN to "8"
// and missed all-caps ids entirely; the /stream hop then 404'd on a
// wrong id. Hop 2's id pattern already carried /i.)
// (forwarding any query params present on the embed URL), play
// resp.media.stream. No token, no signing, no cookies.
// The stream CDN gates on Referer == the embed page URL, on playlist AND
// segment requests alike (Referer https://123av.com/ or none -> 403).
// All hosts are derived per title from the payloads, never hardcoded.

var APP_UA_123AV = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
var DESKTOP_UA_123AV = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

// =============================================================================
// RELAY MODE (1.0.8) — home-PC relay for the hops the devices cannot
// complete themselves (proven 2026-11-23: the iPhone is refused with
// HTTP 404 at the /stream hop and the Apple TV gets no answer from
// 123av.com at all, while the owner's PC on the same LAN completes
// the whole chain). When the app injects the global JTV_RELAY_123AV
// (a base like "http://192.168.68.59:8797/r/<token>", sourced from
// the "relayBase" field of this plugin's plugins.json entry), every
// 123av.com page URL built above and the /stream hop below are
// routed through the relay, which fetches upstream from the home IP
// and returns the body verbatim. Playlists/segments are NOT routed:
// the stream CDN answers the devices directly (Referer-gated only).
// When the global is absent or empty, every function below returns
// exactly what 1.0.7 returned — direct behaviour is unchanged.
// =============================================================================

function relayBase123av() {
    try {
        if (typeof JTV_RELAY_123AV === "string" && JTV_RELAY_123AV) {
            return JTV_RELAY_123AV.replace(/\/+$/, "");
        }
    } catch (e) { }
    return "";
}

// Mirrors the relay service's own allowlist: 123av.com pages, plus
// any host's /stream or /e/ path (embed hosts rotate, so the host
// cannot be pinned). Anything else is never wrapped.
function relayEligible123av(url) {
    if (!url) return false;
    if (url === "https://123av.com" || url.indexOf("https://123av.com/") === 0) return true;
    var m = url.match(/^https?:\/\/[^\/]+(\/[^?#]*)/);
    var path = m ? m[1] : "";
    return path === "/stream" || path.indexOf("/e/") === 0;
}

function relayWrap123av(url, ua, ref) {
    var base = relayBase123av();
    if (!base || !relayEligible123av(url)) return url;
    var out = base + "/fetch?u=" + encodeURIComponent(url) + "&ua=" + (ua || "desk");
    if (ref) out += "&ref=" + encodeURIComponent(ref);
    return out;
}

// Inverse of relayWrap123av for URLs this plugin produced: the app
// hands parse functions the URL it fetched, which in relay mode is
// the relay URL — the resolve logic below keys on the REAL target
// (embed origin + id), so unwrap before use.
function relayUnwrap123av(url) {
    var base = relayBase123av();
    if (!base || !url || url.indexOf(base) !== 0) return url || "";
    var m = url.match(/[?&]u=([^&]+)/);
    if (!m) return url;
    try { return decodeURIComponent(m[1]); } catch (e) { return url; }
}

function parse123avResolve(htmlContent, pageUrl) {
    var url = relayUnwrap123av(pageUrl || "");
    var text = htmlContent || "";

    // Hop 2 — the /stream JSON payload: terminal result.
    var trimmed = text.replace(/^\s+/, "");
    if (trimmed.indexOf("{") === 0) {
        try {
            var data = JSON.parse(trimmed);
            if (data && data.media && typeof data.media.stream === 'string' && data.media.stream) {
                // Referer = the embed page URL. The /stream URL was built
                // from that page, so it carries the same origin and id:
                // rebuild the embed page URL (<origin>/e/<id>) from it.
                // Hop 1 forwarded the embed page's own query params onto
                // the /stream URL after its synthetic id=<id> — which it
                // always writes FIRST. Remove exactly that first id=
                // segment and hand the remainder back verbatim (empty
                // segments included), so the reconstructed Referer is
                // the embed page URL byte-for-byte, query included —
                // even when the embed query carries its own id= param.
                var originM = url.match(/^(https?:\/\/[^\/]+)/i);
                var idM = url.match(/[?&]id=([a-z0-9_]+)/i);
                var referer = url;
                if (originM && idM) {
                    referer = originM[1] + "/e/" + idM[1];
                    var qIdx2 = url.indexOf("?");
                    if (qIdx2 !== -1) {
                        var parts = url.substring(qIdx2 + 1).split("&");
                        for (var pi = 0; pi < parts.length; pi++) {
                            if (/^id=/i.test(parts[pi])) { parts.splice(pi, 1); break; }
                        }
                        if (parts.length) referer += "?" + parts.join("&");
                    }
                }
                return JSON.stringify({
                    url: data.media.stream,
                    isEmbed: false,
                    headers: {
                        "Referer": referer,
                        "User-Agent": APP_UA_123AV
                    },
                    subtitles: []
                });
            }
        } catch (e) { }
    }

    // Hop 1 — the embed page: build the /stream hop, mirroring the embed
    // module script (id from the path; query params forwarded).
    var embedM = url.match(/\/e\/([a-z0-9_]+)/i);
    if (embedM) {
        var originParts = url.match(/^(https?:\/\/[^\/]+)/i);
        var origin = originParts ? originParts[1] : "";
        var streamUrl = origin + "/stream?id=" + embedM[1];
        var qIdx = url.indexOf("?");
        if (qIdx !== -1) {
            // The separator is appended even when the query
            // string is empty, so a trailing "?" on the embed
            // URL survives the chain and hop 2 can hand it
            // back byte-for-byte.
            var qs = url.substring(qIdx + 1);
            streamUrl += "&" + qs;
        }
        // Relay mode: the /stream hop is the one the devices are
        // refused on — carry it via the home-PC relay, with the
        // embed page URL as the upstream Referer, byte-for-byte
        // as built above (query included). No-op when relay is off.
        streamUrl = relayWrap123av(streamUrl, "app", url);
        return JSON.stringify({
            url: streamUrl,
            isEmbed: true,
            headers: {
                "User-Agent": APP_UA_123AV
            },
            subtitles: []
        });
    }

    return null;
}

function parseEmbedResponse(htmlContent, pageUrl) {
    var resolved = parse123avResolve(htmlContent, pageUrl);
    if (resolved) return resolved;
    // Unrecognised shape: keep the pre-rescue behaviour — return the
    // pageUrl as is, marked as an Embed, so the app's EmbedSniffer can
    // automatically load and intercept the m3u8 stream. In relay
    // mode the sniffer needs the REAL embed page, not the relay URL.
    return JSON.stringify({
        url: relayUnwrap123av(pageUrl),
        isEmbed: true,
        headers: {
            "User-Agent": DESKTOP_UA_123AV,
            "Referer": "https://123av.com/"
        },
        subtitles: []
    });
}

function parseDetailResponse(htmlContent, pageUrl) {
    // In the resolver chain this parser runs on the same payloads as
    // parseEmbedResponse (the embed page, then the /stream JSON), so it
    // shares the rescue logic above, including its self-embed fallback.
    return parseEmbedResponse(htmlContent, pageUrl);
}

function parseCategoriesResponse(html) {
    var categories = [];
    var genreRegex = /<a[^>]+href="([^"]*\/genres\/([^"\/]+))"[^>]*>([\s\S]*?)<\/a>/gi;
    var foundGenres = {};
    var match;
    
    while ((match = genreRegex.exec(html)) !== null) {
        var slug = "en/genres/" + match[2];
        var name = PluginUtils.cleanText(match[3]).replace(/\d+,\d+|\d+/g, '').trim();
        if (!name || name.length < 2) continue;
        
        if (!foundGenres[slug]) {
            categories.push({ name: name, slug: slug });
            foundGenres[slug] = true;
        }
    }
    return JSON.stringify(categories);
}

function parseCountriesResponse(html) { return "[]"; }
function parseYearsResponse(html) { return "[]"; }
