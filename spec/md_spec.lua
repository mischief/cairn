-- SPDX-License-Identifier: ISC
package.path = "./?.lua;./?/init.lua;" .. package.path

local md = require "cairn.md"

describe("md", function()
	it("escapes raw HTML", function()
		assert.equal("<p>&lt;script&gt;x&lt;/script&gt; &amp; &quot;q&quot;</p>\n",
		    md.render('<script>x</script> & "q"'))
	end)

	it("renders headings with ids", function()
		assert.equal('<h2 id="log-signature">Log signature</h2>\n',
		    md.render("## Log signature ##"))
	end)

	it("renders emphasis and keeps snake_case whole", function()
		assert.equal("<p><em>a</em> <strong>b <em>c</em></strong> x_y_z "
		    .. "2 * 3 * 4</p>\n",
		    md.render("*a* **b _c_** x_y_z 2 * 3 * 4"))
	end)

	it("renders code spans and fences as text", function()
		assert.equal("<p><code>&lt;b&gt; *x*</code></p>\n",
		    md.render("`<b> *x*`"))
		assert.equal('<pre><code class="language-lua">local x = '
		    .. "&quot;&lt;&quot;\n[[no link]]\n</code></pre>\n",
		    md.render('```lua\nlocal x = "<"\n[[no link]]\n```'))
	end)

	it("follows only safe link schemes", function()
		assert.equal('<p><a href="https://a.b/?c=1&amp;d=2">x</a> bad</p>\n',
		    md.render("[x](https://a.b/?c=1&d=2) [bad](javascript:alert(1))"))
	end)

	it("links bare addresses without the sentence punctuation", function()
		assert.equal('<p>see <a href="https://a.b/c">https://a.b/c</a>.</p>\n',
		    md.render("see https://a.b/c."))
	end)

	it("resolves wikilinks and cairn URIs through the caller", function()
		local o = {
			wiki = function(t)
				return t == "Known" and "/d/known" or nil
			end,
			link = function(u)
				return "/d/" .. u:sub(7)
			end,
		}

		assert.equal('<p><a class="wiki" href="/d/known">Known</a> '
		    .. '<a class="wiki" href="/d/known">label</a> '
		    .. '<span class="wanted">Missing</span> '
		    .. '<a href="/d/abcdefghijklmnop">cairn:abcdefghijklmnop</a></p>\n',
		    md.render("[[Known]] [[Known|label]] [[Missing]] "
		    .. "cairn:abcdefghijklmnop", o))
	end)

	it("renders tight, loose and nested lists", function()
		assert.equal("<ul>\n<li>a</li>\n<li>b\n<ul>\n<li>c</li>\n</ul></li>\n"
		    .. "</ul>\n", md.render("- a\n- b\n  - c"))
		assert.equal("<ol>\n<li><p>a</p>\n<p>more</p></li>\n<li><p>b</p></li>\n"
		    .. "</ol>\n", md.render("1. a\n\n   more\n2. b"))
		assert.equal('<ol start="3">\n<li>a</li>\n</ol>\n', md.render("3. a"))
	end)

	it("joins the wrapped lines of a list item", function()
		assert.equal("<ul>\n<li>a\nb</li>\n</ul>\n", md.render("- a\n  b"))
	end)

	it("renders quotes, rules and tables", function()
		assert.equal("<blockquote>\n<p>a\nb</p>\n</blockquote>\n",
		    md.render("> a\n> b"))
		assert.equal("<hr>\n", md.render("---"))
		assert.equal("<table>\n<thead>\n<tr><th>a</th>"
		    .. '<th class="right">b</th></tr>\n</thead>\n<tbody>\n'
		    .. '<tr><td>1</td><td class="right"><code>x|y</code></td></tr>\n'
		    .. "</tbody>\n</table>\n",
		    md.render("| a | b |\n|---|--:|\n| 1 | `x\\|y` |"))
	end)

	it("shows an image only from the store", function()
		local o = { image = function(u)
			return "/raw/" .. u:sub(7)
		end }

		assert.equal('<p><img src="/raw/abcdefghijklmnop" alt="fig"> '
		    .. '<a href="https://a.b/x.png">far</a></p>\n',
		    md.render("![fig](cairn:abcdefghijklmnop) "
		    .. "![far](https://a.b/x.png)", o))
	end)
end)
