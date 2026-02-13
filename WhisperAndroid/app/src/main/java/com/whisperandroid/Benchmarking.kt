package com.whisperandroid

object Benchmarking {
    fun wordErrorRate(reference: String, hypothesis: String): Double? {
        val ref = tokenizeWords(normalize(reference))
        val hyp = tokenizeWords(normalize(hypothesis))
        if (ref.isEmpty()) return null
        return levenshtein(ref, hyp).toDouble() / ref.size.toDouble()
    }

    fun charErrorRate(reference: String, hypothesis: String): Double? {
        val ref = normalize(reference).toCharArray().toList()
        val hyp = normalize(hypothesis).toCharArray().toList()
        if (ref.isEmpty()) return null
        return levenshtein(ref, hyp).toDouble() / ref.size.toDouble()
    }

    fun normalize(text: String): String {
        val lowered = text.lowercase()
        val cleaned = buildString(lowered.length) {
            lowered.forEach { c ->
                if (c.isLetterOrDigit() || c.isWhitespace()) {
                    append(c)
                } else {
                    append(' ')
                }
            }
        }
        return cleaned.replace("\\s+".toRegex(), " ").trim()
    }

    private fun tokenizeWords(text: String): List<String> {
        return text.split("\\s+".toRegex()).filter { it.isNotBlank() }
    }

    private fun <T> levenshtein(a: List<T>, b: List<T>): Int {
        if (a.isEmpty()) return b.size
        if (b.isEmpty()) return a.size

        var previous = IntArray(b.size + 1) { it }
        var current = IntArray(b.size + 1)

        a.forEachIndexed { i, aChar ->
            current[0] = i + 1
            b.forEachIndexed { j, bChar ->
                val cost = if (aChar == bChar) 0 else 1
                current[j + 1] = minOf(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + cost
                )
            }
            val tmp = previous
            previous = current
            current = tmp
        }
        return previous[b.size]
    }
}
