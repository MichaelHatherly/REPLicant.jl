# Writes `logo.svg` beside this file. Run with `julia assets/logo.jl`.

const RED_L, GREEN_L, PURPLE_L = "#FF6B5E", "#6BDB5A", "#C98BEA"
const W, H = 1200, 400

const GLYPHS = Dict(
    'R' => "11110 10001 10001 11110 10100 10010 10001",
    'E' => "11111 10000 10000 11110 10000 10000 11111",
    'P' => "11110 10001 10001 11110 10000 10000 10000",
    'L' => "10000 10000 10000 10000 10000 10000 11111",
    'a' => "00000 00000 01110 00001 01111 10001 01111",
    'c' => "00000 00000 01110 10000 10000 10001 01110",
    'g' => "00000 00000 01111 10001 10001 01111 00001 01110",
    'i' => "00100 00000 01100 00100 00100 00100 01110",
    'j' => "00010 00000 00110 00010 00010 00010 10010 01100",
    'l' => "01100 00100 00100 00100 00100 00100 01110",
    'n' => "00000 00000 10110 11001 10001 10001 10001",
    'p' => "00000 00000 11110 10001 10001 11110 10000 10000",
    'r' => "00000 00000 10110 11001 10000 10000 10000",
    's' => "00000 00000 01110 10000 01110 00001 11110",
    't' => "01000 01000 11100 01000 01000 01001 00110",
    'u' => "00000 00000 10001 10001 10001 10011 01101",
    '+' => "00000 00000 00100 00100 11111 00100 00100",
    '>' => "10000 01000 00100 00010 00100 01000 10000",
    '$' => "00100 01111 10100 01110 00101 11110 00100",
    ' ' => "00000 00000 00000 00000 00000 00000 00000",
)

const DEFS = """
<style>
@keyframes blink { 50% { opacity: 0 } }
@keyframes fizz { 25% { transform: translate(-7px, 5px) } 50% { transform: translate(4px, -9px) } 75% { transform: translate(-3px, -4px) } }
@keyframes spin { 0%, 45% { transform: rotate(0); animation-timing-function: cubic-bezier(.5, 0, .75, 0) } 70% { transform: rotate(180deg); animation-timing-function: cubic-bezier(.25, 1, .5, 1) } 95%, 100% { transform: rotate(360deg) } }
@keyframes pull { 0%, 45%, 95%, 100% { transform: translate(0, 0) } 70% { transform: translate(var(--in-x), var(--in-y)) } }
.cursor { animation: blink 1.06s steps(1) infinite }
.fizz { animation: fizz .36s steps(1) infinite }
.spin { animation: spin 4s infinite }
.pull { animation: pull 4s ease-in-out infinite }
@media (prefers-reduced-motion: reduce) { .cursor, .fizz, .spin, .pull { animation: none } }
</style>
<filter id="noise" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency=".9" seed="3" stitchTiles="stitch"/><feColorMatrix values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 2.4 0 0 0 -1.1"/></filter>
<filter id="shadow" x="-10%" y="-20%" width="120%" height="140%"><feGaussianBlur stdDeviation="6"/></filter>
<filter id="glow" x="-30%" y="-60%" width="160%" height="220%"><feGaussianBlur stdDeviation="4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
<pattern id="scan" width="3" height="3" patternUnits="userSpaceOnUse"><rect width="3" height="1" fill="#000" opacity=".4"/></pattern>
<radialGradient id="screen" cx=".5" cy=".5" r=".75"><stop offset="0" stop-color="#0f2a1a"/><stop offset="1" stop-color="#030a06"/></radialGradient>
<radialGradient id="vignette" cx=".5" cy=".5" r=".72"><stop offset=".6" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".75"/></radialGradient>
<linearGradient id="bezel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e0d5b6"/><stop offset="1" stop-color="#a69a7a"/></linearGradient>
<radialGradient id="grime" cx=".5" cy=".42" r=".72"><stop offset=".5" stop-color="#3a2a10" stop-opacity="0"/><stop offset="1" stop-color="#3a2a10" stop-opacity=".28"/></radialGradient>
<filter id="grain" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency=".85" numOctaves="2" seed="7"/><feColorMatrix values="0 0 0 0 .22 0 0 0 0 .17 0 0 0 0 .08 1.8 0 0 0 -.8"/></filter>
<filter id="blotch" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency=".006 .018" numOctaves="3" seed="11"/><feColorMatrix values="0 0 0 0 .32 0 0 0 0 .25 0 0 0 0 .1 2.6 0 0 0 -1.2"/></filter>
<linearGradient id="glass" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".12"/><stop offset=".4" stop-color="#fff" stop-opacity="0"/></linearGradient>
"""

num(x) = round(x; digits = 1)

text_width(s, px) = (length(s) * 6 - 1) * px

function rect(io, x, y, w, h, fill; extra = "")
    return println(io, "<rect x=\"", num(x), "\" y=\"", num(y), "\" width=\"", num(w), "\" height=\"", num(h), "\" fill=\"", fill, "\"", extra, "/>")
end

function group(body, io, attributes)
    println(io, "<g ", attributes, ">")
    body()
    return println(io, "</g>")
end

glowing(body, io) = group(body, io, "filter=\"url(#glow)\"")

# Julia's three dots: purple on top, red and green below. Every few seconds they
# spiral one turn into their centre and back out, each trailing the one before.
function julia_dots(io, cx, cy, r)
    d = r * 1.25
    points = ((cx, cy - d * 0.9), (cx - d, cy + d * 0.7), (cx + d, cy + d * 0.7))
    ox, oy = cx, cy + d / 6
    for (k, ((x, y), fill)) in enumerate(zip(points, (PURPLE_L, RED_L, GREEN_L)))
        delay = "animation-delay: $(0.07 * (k - 1))s"
        group(io, "class=\"spin\" style=\"transform-origin: $(num(ox))px $(num(oy))px; $delay\"") do
            inward = "--in-x: $(num(0.4 * (ox - x)))px; --in-y: $(num(0.4 * (oy - y)))px"
            group(io, "class=\"pull\" style=\"$inward; $delay\"") do
                println(io, "<circle cx=\"", num(x), "\" cy=\"", num(y), "\" r=\"", num(r), "\" fill=\"", fill, "\"/>")
            end
        end
    end
    return nothing
end

# `fill` is a colour, or a function of the character index. `i_dot` draws the dot
# of each `i` as a `:pixel`, as Julia's three dots (`:julia`), or leaves it out (`:none`).
function pixel_text(io, s, x, y, px, fill; i_dot = :pixel, gap = px / 10)
    for (k, ch) in enumerate(s)
        ox = x + (k - 1) * 6 * px
        for (r, row) in enumerate(split(GLYPHS[ch])), (c, bit) in enumerate(row)
            bit == '1' || continue
            if ch == 'i' && r == 1 && i_dot !== :pixel
                i_dot === :julia && julia_dots(io, ox + 2.5px, y - 0.6px, 0.62px)
            else
                rect(io, ox + (c - 1) * px + gap / 2, y + (r - 1) * px + gap / 2, px - gap, px - gap, fill isa Function ? fill(k) : fill)
            end
        end
    end
    return nothing
end

# Red and cyan ghosts either side of the text, as on a misconverged tube.
function aberrated(io, s, x, y, px, fill; offset = 2)
    for (dx, colour) in ((-offset, "#ff2d6f"), (offset, "#2de1ff"))
        group(io, "opacity=\".55\" style=\"mix-blend-mode:screen\"") do
            pixel_text(io, s, x + dx, y, px, colour; i_dot = :none)
        end
    end
    return glowing(io) do
        pixel_text(io, s, x, y, px, fill; i_dot = :julia)
    end
end

function screen_content(io, sx, sy, sw, sh)
    word, big = "REPLicant", 15
    x = sx + (sw - text_width(word, big) - 6big) / 2
    y = sy + (sh - 7big) / 2 + 12
    tag = "\$ julia +rpc"
    glowing(io) do
        pixel_text(io, "julia> using REPLicant", sx + 40, sy + 26, 4, GREEN_L)
    end
    aberrated(io, word, x, y, big, k -> k <= 4 ? RED_L : "#eaffea")
    rect(io, x + text_width(word, big) + big, y + 6big, 5big, big, GREEN_L; extra = " class=\"cursor\" filter=\"url(#glow)\"")
    return group(io, "opacity=\".8\"") do
        glowing(io) do
            pixel_text(io, tag, sx + sw - 40 - text_width(tag, 4), sy + sh - 54, 4, GREEN_L)
        end
    end
end

function logo(io)
    x, y, w, h = 40, 24, 1120, 352
    sx, sy, sw, sh = x + 32, y + 28, w - 64, h - 56
    println(io, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 $W $H\" width=\"$W\" height=\"$H\" role=\"img\" aria-label=\"REPLicant\">")
    println(io, "<title>REPLicant</title>")
    println(io, "<defs>", DEFS, "</defs>")
    rect(io, x + 6, y + 10, w - 12, h - 6, "#000"; extra = " rx=\"34\" opacity=\".35\" filter=\"url(#shadow)\"")
    rect(io, x, y, w, h, "url(#bezel)"; extra = " rx=\"34\"")
    print(io, "<clipPath id=\"bezel-clip\">")
    rect(io, x, y, w, h, "none"; extra = " rx=\"34\"")
    println(io, "</clipPath>")
    group(io, "clip-path=\"url(#bezel-clip)\"") do
        rect(io, x, y, w, h, "#000"; extra = " filter=\"url(#blotch)\" opacity=\".35\"")
        rect(io, x, y, w, h, "#000"; extra = " filter=\"url(#grain)\" opacity=\".45\"")
        rect(io, x, y, w, h, "url(#grime)")
    end
    rect(io, sx - 6, sy - 6, sw + 12, sh + 12, "#4a4436"; extra = " rx=\"44\" opacity=\".6\"")
    rect(io, sx, sy, sw, sh, "url(#screen)"; extra = " rx=\"40\"")
    print(io, "<clipPath id=\"screen-clip\">")
    rect(io, sx, sy, sw, sh, "none"; extra = " rx=\"40\"")
    println(io, "</clipPath>")
    group(io, "clip-path=\"url(#screen-clip)\"") do
        screen_content(io, sx, sy, sw, sh)
        rect(io, sx, sy, sw, sh, "url(#scan)")
        rect(io, sx - 20, sy - 20, sw + 40, sh + 40, "#fff"; extra = " class=\"fizz\" filter=\"url(#noise)\" opacity=\".09\"")
        rect(io, sx, sy, sw, sh, "url(#vignette)")
        println(io, "<path d=\"M$sx $sy h", num(0.55sw), " q-", num(0.25sw), " ", num(0.25sh), " -", num(0.55sw), " ", num(0.55sh), "z\" fill=\"url(#glass)\"/>")
    end
    return println(io, "</svg>")
end

open(logo, joinpath(@__DIR__, "logo.svg"), "w")
