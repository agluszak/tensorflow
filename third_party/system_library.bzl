ENV_VAR_PREFIX = "bazel_"
ENV_VAR_LIB_PREFIX = "lib_"
ENV_VAR_INCLUDE_PREFIX = "include_"
ENV_VAR_SEPARATOR = ";"

def _make_flags(array_of_strings, prefix):
    flags = []
    if array_of_strings:
        for s in array_of_strings:
            flags.append(prefix + s)
    return " ".join(flags)

def _split_env_var(repo_ctx, var_name):
    return []

    # TODO remove
    value = repo_ctx.os.environ[var_name]
    if value:
        return value.split(ENV_VAR_SEPARATOR)
    else:
        return []

def _execute_bash(repo_ctx, cmd):
    return repo_ctx.execute(["/bin/bash", "-c", cmd])

def _find_linker(repo_ctx):
    ld = _execute_bash(repo_ctx, "which ld").stdout.replace("\n", "")
    lld = _execute_bash(repo_ctx, "which lld").stdout.replace("\n", "")
    if ld:
        return ld
    elif lld:
        return lld
    else:
        fail("No linker found")

def _find_compiler(repo_ctx):
    gcc = _execute_bash(repo_ctx, "which g++").stdout.replace("\n", "")
    clang = _execute_bash(repo_ctx, "which clang++").stdout.replace("\n", "")
    if gcc:
        return gcc
    elif clang:
        return clang
    else:
        fail("No compiler found")

def _find_lib_path(repo_ctx, lib_name, archive_name, lib_path_hints):
    override_paths_var_name = ENV_VAR_PREFIX + ENV_VAR_LIB_PREFIX + lib_name + "_override_paths"
    override_paths = _split_env_var(repo_ctx, override_paths_var_name)
    path_flags = _make_flags(override_paths + lib_path_hints, "-L")
    linker = _find_linker(repo_ctx)
    cmd = """
          {} -verbose -l:{} {} 2>/dev/null | \\
          grep succeeded | \\
          sed -e 's/^\s*attempt to open //' -e 's/ succeeded\s*$//'
          """.format(
        linker,
        archive_name,
        path_flags,
    )
    result = repo_ctx.execute(["/bin/bash", "-c", cmd])

    # No idea where that newline comes from
    return result.stdout.replace("\n", "")

def _find_header_path(repo_ctx, lib_name, header_name, includes):
    override_paths_var_name = ENV_VAR_PREFIX + ENV_VAR_INCLUDE_PREFIX + lib_name + "_override_paths"
    additional_paths_var_name = ENV_VAR_PREFIX + ENV_VAR_INCLUDE_PREFIX + lib_name + "_paths"
    override_paths = _split_env_var(repo_ctx, override_paths_var_name)
    additional_paths = _split_env_var(repo_ctx, additional_paths_var_name)

    # See https://gcc.gnu.org/onlinedocs/gcc/Directory-Options.html
    override_include_flags = _make_flags(override_paths, "-I")
    standard_include_flags = _make_flags(includes, "-isystem")
    additional_include_flags = _make_flags(additional_paths, "-idirafter")

    compiler = _find_compiler(repo_ctx)

    # Taken from https://stackoverflow.com/questions/63052707/which-header-exactly-will-c-preprocessor-include/63052918#63052918
    cmd = """
          f=\"{}\"; \\
          echo | \\
          {} -E {} {} {} -Wp,-v - 2>&1 | \\
          sed '\\~^ /~!d; s/ //' | \\
          while IFS= read -r path; \\
              do if [[ -e \"$path/$f\" ]]; \\
                  then echo \"$path/$f\";  \\
                  break; \\
              fi; \\
          done
          """.format(
        header_name,
        compiler,
        override_include_flags,
        standard_include_flags,
        additional_include_flags,
    )
    result = repo_ctx.execute(["/bin/bash", "-c", cmd])
    return result.stdout.replace("\n", "")

def _get_archive_name(lib_name, static):
    if static:
        return "lib" + lib_name + ".a"
    else:
        return "lib" + lib_name + ".so"

def system_library_impl(repo_ctx):
    repo_name = repo_ctx.attr.name
    lib_name = repo_ctx.attr.lib_name
    includes = repo_ctx.attr.includes
    hdrs = repo_ctx.attr.hdrs
    optional_hdrs = repo_ctx.attr.optional_hdrs
    deps = repo_ctx.attr.deps
    lib_path_hints = repo_ctx.attr.lib_path_hints
    linkstatic = repo_ctx.attr.linkstatic
    lib_archive_names = repo_ctx.attr.lib_archive_names

    archive_found_path = ""
    archive_fullname = ""
    for name in lib_archive_names:
        archive_fullname = _get_archive_name(name, linkstatic)
        archive_found_path = _find_lib_path(repo_ctx, lib_name, name, lib_path_hints)
        if archive_found_path:
            break

    if not archive_found_path:
        fail("Library {} could not be found".format(lib_name))

    static_library_param = "static_library = \"{}\",".format(archive_fullname) if linkstatic else ""
    shared_library_param = "shared_library = \"{}\",".format(archive_fullname) if not linkstatic else ""
    repo_ctx.symlink(archive_found_path, archive_fullname)
    hdr_names = []
    hdr_paths = []
    for hdr in hdrs:
        hdr_path = _find_header_path(repo_ctx, lib_name, hdr, includes)
        if hdr_path:
            repo_ctx.symlink(hdr_path, hdr)
            hdr_names.append(hdr)
            hdr_paths.append(hdr_path)
        else:
            fail("Could not find required header {}".format(hdr))

    for hdr in optional_hdrs:
        hdr_path = _find_header_path(repo_ctx, lib_name, hdr, includes)
        if hdr_path:
            repo_ctx.symlink(hdr_path, hdr)
            hdr_names.append(hdr)
            hdr_paths.append(hdr_path)

    hdrs_param = "hdrs = {},".format(str(hdr_names))

    # This is needed for the case when quote-includes and system-includes alternate in the include chain, i.e.
    # #include <SDL2/SDL.h> -> #include "SDL_main.h" -> #include <SDL2/_real_SDL_config.h> -> #include "SDL_platform.h"
    # The problem is that the quote-includes are assumed to be
    # in the same directory as the header they are included from - they have no subdir prefix ("SDL2/") in their paths
    include_subdirs = {}
    for hdr in hdr_names:
        path_segments = hdr.split("/")
        path_segments.pop()
        current_path_segments = ["external", repo_name, "remote"]
        for segment in path_segments:
            current_path_segments.append(segment)
            current_path = "/".join(current_path_segments)
            include_subdirs.update({current_path: None})
        include_subdirs.update({"bazel-out/k8-opt-exec-8EC663B4/bin/external/" + repo_name + "/remote": None})
        include_subdirs.update({"bazel-out/k8-opt-exec-DEE97DD4/bin/external/" + repo_name + "/remote": None})
        include_subdirs.update({"bazel-out/k8-opt/bin/external/" + repo_name + "/remote": None})

    includes_param = "includes = {},".format(str(include_subdirs.keys()))

    deps_names = []
    for dep in deps:
        dep_name = repr("@" + dep)
        deps_names.append(dep_name)
    deps_param = "deps = [{}],".format(",".join(deps_names))

    link_hdrs_command = ""
    remote_hdrs = []
    for path, hdr in zip(hdr_paths, hdr_names):
        remote_hdr = "remote/" + hdr
        remote_hdrs.append(remote_hdr)
        link_hdrs_command += "mkdir -p $(RULEDIR)/remote && cp {path} $(RULEDIR)/{hdr}\n".format(path = path, hdr = remote_hdr)

    remote_archive_fullname = "remote/" + archive_fullname
    link_library_command = "mkdir -p $(RULEDIR)/remote && cp {path} $(RULEDIR)/{lib}".format(path = archive_found_path, lib = remote_archive_fullname)

    remote_library_param = "static_library = \"remote_link_archive\"," if linkstatic else "shared_library = \"remote_link_archive\","

    repo_ctx.file(
        "BUILD",
        executable = False,
        content =
            """
load("@bazel_tools//tools/build_defs/cc:cc_import.bzl", "cc_import")
cc_import(
    name = "local_includes",
    {static_library}
    {shared_library}
    {hdrs}
    {deps}
    {includes}
)

genrule(
    name = "remote_link_headers",
    outs = {remote_hdrs},
    cmd = {link_hdrs_command}
)

genrule(
    name = "remote_link_archive",
    outs = ["{remote_archive_fullname}"],
    cmd = {link_library_command}
)

cc_import(
    name = "remote_includes",
    hdrs = [":remote_link_headers"],
    {remote_library_param}
    {deps}
    {includes}
)

alias(
    name = "{name}",
    actual = select({{
        "@bazel_tools//src/conditions:remote": "remote_includes",
        "//conditions:default": "local_includes",
    }}),
    visibility = ["//visibility:public"],
)
""".format(
                static_library = static_library_param,
                shared_library = shared_library_param,
                hdrs = hdrs_param,
                deps = deps_param,
                hdr_names = str(hdr_names),
                archive_fullname = archive_fullname,
                link_hdrs_command = repr(link_hdrs_command),
                link_library_command = repr(link_library_command),
                remote_library_param = remote_library_param,
                name = lib_name,
                includes = includes_param,
                remote_hdrs = remote_hdrs,
                remote_archive_fullname = remote_archive_fullname,
            ),
    )

system_library = repository_rule(
    implementation = system_library_impl,
    local = True,
    remotable = True,
    environ = [],
    attrs = {
        "lib_name": attr.string(mandatory = True),
        "lib_archive_names": attr.string_list(),
        "lib_path_hints": attr.string_list(),
        "includes": attr.string_list(),
        "hdrs": attr.string_list(mandatory = True, allow_empty = False),
        "optional_hdrs": attr.string_list(),
        "deps": attr.string_list(),
        "linkstatic": attr.bool(),
    },
)
