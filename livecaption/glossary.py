"""Store preferred translations and select terms relevant to a piece of text."""

import re

from preferences import appearance_path, read_preferences, write_preferences


MAX_TERMS = 100
MAX_TERM_LENGTH = 80
MAX_TEXT_TERMS = 20


def clean_pair(source, target):
    if not isinstance(source, str) or not isinstance(target, str):
        raise ValueError("请输入原文术语和指定译法。")
    source, target = source.strip(), target.strip()
    if not source or not target:
        raise ValueError("请输入原文术语和指定译法。")
    if not (source.isprintable() and target.isprintable()):
        raise ValueError("原文和译法请各填一行。")
    if max(len(source), len(target)) > MAX_TERM_LENGTH:
        raise ValueError(f"原文和译法各限 {MAX_TERM_LENGTH} 个字符。")
    return " ".join(source.split()), target


def load_glossary():
    rows = read_preferences(appearance_path().with_name("glossary.json")).get("terms")
    if not isinstance(rows, list):
        return ()
    pairs = {}
    for row in rows[:MAX_TERMS]:
        if isinstance(row, list) and len(row) == 2:
            try:
                source, target = clean_pair(*row)
            except ValueError:
                continue
            pairs.setdefault(source.casefold(), (source, target))
    return tuple(pairs.values())


def save_glossary(terms):
    terms = tuple(clean_pair(*term) for term in terms)
    if len(terms) > MAX_TERMS:
        raise ValueError(f"词表最多保存 {MAX_TERMS} 条术语。")
    if len({source.casefold() for source, _ in terms}) != len(terms):
        raise ValueError("这条原文已存在，请选中已有术语再修改。")
    write_preferences(appearance_path().with_name("glossary.json"), {"terms": terms})
    return terms


def matching_terms(text, terms):
    matched = []
    spans = []
    # Prefer a longer phrase if two entries cover the same part of a sentence.
    for source, target in sorted(terms, key=lambda pair: len(pair[0]), reverse=True):
        pattern = r"\s+".join(re.escape(word) for word in source.split())
        if re.fullmatch(r"[A-Za-z0-9_]", source[0]):
            pattern = r"(?<![A-Za-z0-9_])" + pattern
        if re.fullmatch(r"[A-Za-z0-9_]", source[-1]):
            pattern += r"(?![A-Za-z0-9_])"
        for match in re.finditer(pattern, text, re.IGNORECASE):
            start, end = match.span()
            if all(end <= left or start >= right for left, right in spans):
                matched.append({"source": match.group(), "target": target})
                spans.append((start, end))
                break
        if len(matched) == MAX_TEXT_TERMS:
            break
    return matched
