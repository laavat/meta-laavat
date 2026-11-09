#!/usr/bin/env python
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy

"""The layer is glue. These checks keep it that way.

Signing logic lives in signing-tool, where it can be unit-tested without a
build system, not on bitbake's own interpreter path inside the layer.

Nothing here needs bitbake: the checks read the class text. That is the point -
CI has no bitbake, so a rule that needed one would never run.
"""

import os
import re
import subprocess
import textwrap

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
LAYER = os.path.dirname(HERE)
CLASSES = os.path.join(LAYER, "classes")

# Measured, not guessed. The engine (laavat-sign) and the u-boot FIT surgery
# (laavat-fitkey-uboot) are the two big ones; everything else is well under.
# Raise this only with a reason, and never to make room for logic.
MAX_CLASS_LINES = 75

# Graph shape has to be decided at parse time and bitbake offers no non-Python
# hook for it. These are the only Python allowed, they may only guard the task
# graph, and they may not read the layer's own variables - anything that needs
# a LAAVAT_* value belongs in the task, where it can be tested.
MAX_ANONYMOUS_BLOCKS = 4


def classes():
    return sorted(f for f in os.listdir(CLASSES) if f.endswith(".bbclass"))


def text(name):
    with open(os.path.join(CLASSES, name), encoding="utf-8") as f:
        return f.read()


def code_lines(body):
    return [l for l in body.splitlines()
            if l.strip() and not l.strip().startswith("#")]


def _task_bodies(body):
    """Every shell function in a class, including do_*:append."""
    return re.finditer(r"^([a-z_]+(?::append)?)\(\) \{(.*?)^\}", body, re.S | re.M)


def test_there_are_classes_to_check():
    assert classes(), "no bbclasses found - the test is pointed at the wrong tree"


def test_no_python_tasks_or_helpers():
    """A python task means logic, and logic belongs where it can be tested."""
    offenders = []
    for name in classes():
        for line in text(name).splitlines():
            if re.match(r"^python\s+do_\w+\s*\(", line) or re.match(r"^def\s+\w+\(", line):
                offenders.append("{}: {}".format(name, line.strip()))
    assert offenders == [], (
        "python tasks/helpers are back in the layer:\n  " + "\n  ".join(offenders))


def test_anonymous_blocks_only_shape_the_graph():
    found = [n for n in classes() if "python __anonymous" in text(n)]
    assert len(found) <= MAX_ANONYMOUS_BLOCKS, (
        "more parse-time python than the graph needs: {}".format(found))
    for name in found:
        block = re.search(r"^python __anonymous\(\).*?^\}", text(name),
                          re.S | re.M).group(0)
        assert "LAAVAT_" not in block, (
            "{}: an __anonymous block reads a LAAVAT_ variable. Anything that "
            "depends on this layer's own configuration belongs in a task, "
            "where it can be exercised without bitbake.".format(name))


def test_no_inline_python_expressions():
    """${@...} is the escape valve that would make every other rule here moot."""
    offenders = [n for n in classes() if "${@" in text(n)]
    assert offenders == [], "inline python expressions in: {}".format(offenders)


def test_the_layer_ships_no_python_library():
    assert not os.path.isdir(os.path.join(LAYER, "lib")), (
        "meta-laavat/lib exists. Code there sits on bitbake's own interpreter "
        "path; signing logic belongs in signing-tool.")
    conf = os.path.join(LAYER, "conf", "layer.conf")
    with open(conf, encoding="utf-8") as f:
        assert "addpylib" not in f.read(), (
            "layer.conf places python on bitbake's path again")


@pytest.mark.parametrize("name", classes())
def test_class_stays_small(name):
    n = len(code_lines(text(name)))
    assert n <= MAX_CLASS_LINES, (
        "{} is {} lines of code, over the {} budget. A class is variables, "
        "addtask, task flags and one exec.".format(name, n, MAX_CLASS_LINES))


# --- the token, which is the one thing a mistake here leaks -----------------

@pytest.mark.parametrize("name", classes())
def test_the_token_is_passed_as_a_path(name):
    """A shell task's body is written to ${T}/run.* with variables expanded.

    So a token in a variable is a token on disk. It is passed as a path and the
    CLI reads the file itself.
    """
    body = text(name)
    for bad in ("$(cat ${LAAVAT_TOKEN_FILE}", "$(< ${LAAVAT_TOKEN_FILE}",
                "$(cat ${LAAVAT_APPROVER_TOKEN_FILE}"):
        assert bad not in body, (
            "{}: the token is being read into the command line. Pass the path: "
            '-t "@${{LAAVAT_TOKEN_FILE}}"'.format(name))
    if "-t " in body:
        assert '-t "@${LAAVAT_TOKEN_FILE}"' in body, (
            "{}: -t must be given the token *path*".format(name))


def test_functions_that_use_the_token_exclude_it_from_their_signature():
    """Otherwise moving the token file re-hashes the task and re-signs - which
    for a four-eyes operation spends a second approval on unchanged bytes.

    The flag must sit on the function whose body carries the reference, not merely on the
    task: bb.data.build_dependencies subtracts vardepsexclude from a key's DIRECT references
    only, and generate_dependency_hash then unions in gendeps[dep] for every called function
    with no exclusion applied. A task-level flag alone left the token path in the signature.
    """
    token = re.compile(r"LAAVAT_(?:APPROVER_)?TOKEN_FILE")
    checked = 0
    for name in classes():
        body = text(name)
        for match in re.finditer(r"^([a-z_]+(?::(?:append|prepend))?)\(\) \{(.*?)^\}",
                                 body, re.S | re.M):
            func, func_body = match.group(1), match.group(2)
            if not token.search(func_body):
                continue
            checked += 1
            flag = re.search(r"^{}\[vardepsexclude\][^\n]*".format(re.escape(func)),
                             body, re.M)
            assert flag and token.search(flag.group(0)), (
                "{}: {} references the token path but no {}[vardepsexclude] names it; a flag "
                "on the calling task does not prune a reference made here".format(
                    name, func, func))
    assert checked, "no function references the token path - has the CLI contract changed?"


def test_tasks_that_run_the_client_depend_on_it():
    """DEPENDS alone does not stage the native tool for a bare `-c <task>`."""
    for name in classes():
        body = text(name)
        for match in re.finditer(r"^(do_laavat_\w+)\(\) \{(.*?)^\}", body, re.S | re.M):
            task, task_body = match.group(1), match.group(2)
            if "signing-tool " not in task_body:
                continue
            assert "{}[depends]".format(task) in body, (
                "{}: {} runs signing-tool but declares no task-level "
                "[depends] on signing-tool-native".format(name, task))


# --- syntax, since nothing else in CI ever runs these ------------------------

def test_every_shell_body_parses():
    """CI has no bitbake, so `sh -n` is the only thing that reads these at all."""
    stub = ("bbfatal() { echo \"$*\" >&2; exit 1; }\n"
            "bbwarn() { echo \"$*\" >&2; }\n"
            "bbnote() { echo \"$*\"; }\n")
    for name in classes():
        for match in re.finditer(r"^([a-z_]+)\(\) \{(.*?)^\}", text(name),
                                 re.S | re.M):
            fn, body = match.group(1), match.group(2)
            r = subprocess.run(["sh", "-n"], input=stub + body,
                               capture_output=True, text=True)
            assert r.returncode == 0, "{}: {} is not valid shell:\n{}".format(
                name, fn, r.stderr)


def test_every_python_block_compiles():
    for name in classes():
        for match in re.finditer(r"^python __anonymous\(\) \{(.*?)^\}",
                                 text(name), re.S | re.M):
            # bbclass python blocks are indented inside the braces.
            compile(textwrap.dedent(match.group(1)),
                    "{}:__anonymous".format(name), "exec")


# --- the seam: the flags the layer uses must be flags the client has ---------

def _client_options():
    """{subcommand: set(option strings)} straight out of the real parser.

    Not a copy of the flag names - the parser itself. A renamed or dropped
    option in signing-tool breaks this layer at build time on a Yocto host,
    long after the change, and nothing on either side would otherwise notice.

    Each subcommand inherits its ancestors' options: -a, -c and -t are the root
    parser's, and every credentialed call the layer makes carries them.
    """
    import argparse

    seen = {}

    def walk(parser, path, inherited):
        opts = set(inherited)
        subs = []
        for action in parser._actions:
            if isinstance(action, argparse._SubParsersAction):
                subs.append(action)
            else:
                opts.update(action.option_strings)
        if path:
            seen.setdefault(path[-1], set()).update(opts)
        for action in subs:
            for name, sub in action.choices.items():
                walk(sub, path + [name], opts)

    walk(_root_parser(), [], set())
    return seen


def _root_parser():
    """ParseArgs() parses sys.argv, so hand it something that parses cleanly.

    --help would print and exit before returning the tree.
    """
    import sys
    from unittest import mock
    from signingtool import parsers
    argv = ["signing-tool", "-c", "-a", "https://x/api/v1", "-t", "tok",
            "imagesigning", "getall"]
    with mock.patch.object(sys, "argv", argv):
        parser, _ = parsers.ParseArgs()
    return parser


def _calls(body):
    """Each `signing-tool ...` invocation, joined across its \\ continuations.

    Bounded at the first line that does not continue: past that is the next
    command, where a shell test operator looks exactly like a short option.
    """
    lines = body.splitlines()
    out = []
    for i, line in enumerate(lines):
        if not re.search(r"(?<![-\w])signing-tool\b", line):
            continue
        call, j = [], i
        while j < len(lines):
            call.append(lines[j])
            if not lines[j].rstrip().endswith("\\"):
                break
            j += 1
        out.append(" ".join(call))
    return out


def _flags(text_):
    """Both spellings. -F is as easy to rename as --max-bytes, and the layer
    passes far more short options than long ones."""
    return re.findall(r"(?<![\w-])(--?[a-zA-Z][\w-]*)", text_)


def test_every_flag_the_layer_passes_exists_in_the_client():
    pytest.importorskip("signingtool",
                        reason="signing-tool is not installed in this environment")
    options = _client_options()
    problems = []
    checked = 0
    for name in classes():
        for match in _task_bodies(text(name)):
            body = match.group(2)
            calls = _calls(body)
            if not calls:
                continue
            verbs = set()
            for call in calls:
                m = (re.search(r"imagesigning\s+([a-z-]+)", call)
                     or re.search(r"\bproduct\s+([a-z]+)", call))
                if m:
                    verbs.add(m.group(1))
            if len(verbs) != 1:
                problems.append("{}: {} runs {} subcommands; the flag check "
                                "assumes one".format(name, match.group(1),
                                                     len(verbs)))
                continue
            verb = verbs.pop()
            known = options.get(verb)
            if known is None:
                problems.append("{}: no such subcommand '{}'".format(name, verb))
                continue
            # Flags reach the CLI two ways: on the command line, and through the
            # positional list the task builds with `set --`. Both are the seam.
            passed = []
            for call in calls:
                passed += _flags(call)
            for line in body.splitlines():
                if re.match(r"\s*set --", line):
                    passed += _flags(line)
            for flag in passed:
                checked += 1
                if flag not in known:
                    problems.append("{}: '{}' is not an option of '{}'".format(
                        name, flag, verb))
    assert problems == [], (
        "the layer passes flags the client does not have:\n  "
        + "\n  ".join(sorted(set(problems))))
    assert checked > 40, (
        "only {} flags checked - the extraction stopped matching the "
        "classes".format(checked))


# --- LAAVAT_SIGN_SKIP, the path a consumer without an account takes ----------

def test_skip_reaches_every_task_that_consumes_signed_output():
    """LAAVAT_SIGN_SKIP makes the signing tasks do nothing, so anything that
    installs what they would have produced must not run either.

    Without this the README's promise - build a tier with no account - fails at
    do_deploy on a file do_laavat_sign deliberately did not write.
    """
    problems = []
    for name in classes():
        body = text(name)
        for match in _task_bodies(body):
            # Code only: a comment naming the variable is not a check on it.
            task = match.group(1)
            task_body = "\n".join(code_lines(match.group(2)))
            consumes = ("LAAVAT_SIGN_OUTPUT" in task_body
                        or "LAAVAT_SIGN_DIR" in task_body
                        or "UBOOT_SIGN_KEYNAME}.crt" in task_body)
            # laavat_sign_common does the check on behalf of its callers.
            if not consumes or "laavat_sign_common" in task_body:
                continue
            if "LAAVAT_SIGN_SKIP" not in task_body:
                problems.append("{}: {}".format(name, task))
    assert problems == [], (
        "these consume what a skipped signing task never wrote, without "
        "checking LAAVAT_SIGN_SKIP:\n  " + "\n  ".join(problems))


# --- SRC_URI files do not land in WORKDIR any more ---------------------------

def test_fetched_files_are_read_from_unpackdir():
    """file:// lands in ${WORKDIR} only on Yocto 5.0. 5.1 and 5.2 put it in
    ${WORKDIR}/sources-unpack, 5.3 and later in ${WORKDIR}/sources - so a class
    that reads its own SRC_URI file out of ${WORKDIR} works on exactly one of
    the five releases this layer claims.
    """
    offenders = []
    for name in classes():
        body = text(name)
        if "SRC_URI" not in body:
            continue
        # Code only: a comment mentioning UNPACKDIR is not a lookup in it.
        code = "\n".join(code_lines(body))
        if "UNPACKDIR" not in code:
            offenders.append("{}: never looks in ${{UNPACKDIR}}".format(name))
        # A class is parsed after bitbake.conf, and the last ??= wins, so
        # defaulting UNPACKDIR here would move every source the recipe fetches.
        if re.search(r"^UNPACKDIR\s*[?:+]*=", code, re.M):
            offenders.append("{}: assigns UNPACKDIR".format(name))
    assert offenders == [], (
        "a class that fetches its own file must find it where the release "
        "actually unpacks:\n  " + "\n  ".join(offenders))

# --- fitImage-none is only the deployed FIT while the bundle is off ----------

def test_a_class_that_signs_fitimage_none_refuses_a_bundled_initramfs():
    """poky's kernel-fitimage assembles fitImage-bundle when
    INITRAMFS_IMAGE_BUNDLE is set, points fitImage at it, and then skips
    installing fitImage in do_install - so signing fitImage-none there leaves
    the deployed and booted image carrying the placeholder signature. Green
    build, device refuses every kernel.
    """
    offenders = []
    for name in classes():
        code = "\n".join(code_lines(text(name)))
        if "fitImage-none" not in code:
            continue
        if "INITRAMFS_IMAGE_BUNDLE" not in code:
            offenders.append(name)
    assert offenders == [], (
        "these sign fitImage-none without refusing a bundled initramfs, which "
        "is the one configuration where that file reaches nothing:\n  "
        + "\n  ".join(offenders))


# pip name -> recipe name where they differ; configparser is the Python 3 standard library module
RECIPE_NAMES = {"python-dateutil": "python3-dateutil", "configparser": None}


def _client_rdepends():
    recipes = os.path.join(LAYER, "recipes-devtools", "signing-tool")
    (recipe,) = [f for f in os.listdir(recipes) if f.startswith("signing-tool_") and f.endswith(".bb")]
    with open(os.path.join(recipes, recipe), encoding="utf-8") as f:
        body = re.search(r'RDEPENDS:\$\{PN\} = "(.*?)"', f.read(), re.S).group(1)
    return set(body.replace("\\", " ").split())


def test_every_runtime_dependency_of_the_client_is_in_rdepends():
    pytest.importorskip("signingtool", reason="signing-tool is not installed in this environment")
    from importlib import metadata
    reqs = [r for r in metadata.requires("signing-tool") or [] if "extra ==" not in r]
    names = [re.split(r"[<>=!~;\[ ]", r, maxsplit=1)[0].lower() for r in reqs]
    assert names, "signing-tool metadata lists no dependencies"
    wanted = {RECIPE_NAMES.get(n, "python3-" + n) for n in names} - {None}
    assert sorted(wanted - _client_rdepends()) == []
