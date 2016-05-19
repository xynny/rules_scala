# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Rules for supporting the Scala language."""

_jar_filetype = FileType([".jar"])
_scala_filetype = FileType([".scala"])
_srcjar_filetype = FileType([".srcjar"])
# TODO is there a way to derive this from the above?
_scala_srcjar_filetype = FileType([".scala", ".srcjar"])

def _adjust_resources_path(path):
  dir_1, dir_2, rel_path = path.partition("resources")
  if rel_path:
    return dir_1 + dir_2, rel_path
  (dir_1,dir_2,rel_path) = path.partition("java")
  if rel_path:
    return dir_1 + dir_2, rel_path
  return "", path

def _add_resources_cmd(ctx):
  res_cmd = ""
  for f in ctx.files.resources:
    c_dir, res_path = _adjust_resources_path(f.path)
    change_dir = "-C " + c_dir if c_dir else ""
    res_cmd += "\n{jar} uf {out} " + change_dir + " " + res_path
  return res_cmd

def _build_nosrc_jar(ctx, buildijar):
  res_cmd = _add_resources_cmd(ctx)
  ijar_cmd = ""
  if buildijar:
    ijar_cmd = "\ncp {out} {ijar_out}".format(
      out=ctx.outputs.jar.path,
      ijar_out=ctx.outputs.ijar.path)
  cmd = """
set -e
# Make jar file deterministic by setting the timestamp of files
touch -t 198001010000 {manifest}
zip -X -q -FS {out} {manifest}
""" + ijar_cmd + res_cmd
  cmd = cmd.format(
      out=ctx.outputs.jar.path,
      manifest=ctx.outputs.manifest.path,
      jar=ctx.file._jar.path)
  outs = [ctx.outputs.jar]
  if buildijar:
    outs.extend([ctx.outputs.ijar])
  ctx.action(
      inputs=
          ctx.files.resources +
          ctx.files._jdk +
          [ctx.outputs.manifest, ctx.file._jar],
      outputs=outs,
      command=cmd,
      progress_message="scala %s" % ctx.label,
      arguments=[])

def _collect_plugin_paths(plugins):
  paths = set()
  for p in plugins:
    if hasattr(p, "path"):
      paths += [p.path]
    elif hasattr(p, "scala"):
      paths += [p.scala.outputs.jar.path]
    elif hasattr(p, "java"):
      paths += [j.class_jar.path for j in p.java.outputs.jars]
    # support http_file pointed at a jar. http_jar uses ijar, which breaks scala macros
    elif hasattr(p, "files"):
      paths += [f.path for f in p.files]
  return paths

def _compile(ctx, _jars, dep_srcjars, buildijar):
  jars = _jars
  res_cmd = _add_resources_cmd(ctx)
  ijar_cmd = ""
  if buildijar:
    ijar_cmd = "\n{ijar} {out} {ijar_out}".format(
      ijar=ctx.file._ijar.path,
      out=ctx.outputs.jar.path,
      ijar_out=ctx.outputs.ijar.path)

  sources = _scala_filetype.filter(ctx.files.srcs)
  srcjars = _srcjar_filetype.filter(ctx.files.srcs)
  all_srcjars = set(srcjars + list(dep_srcjars))
  # look for any plugins:
  plugins = _collect_plugin_paths(ctx.attr.plugins)
  plugin_arg = ""
  if (len(plugins) > 0):
    plugin_arg = " ".join(["-Xplugin:%s" % p for p in plugins])

  # Set up the args to pass to scalac because they can be too long for bash
  scalac_args_file = ctx.new_file(ctx.outputs.jar, ctx.outputs.jar.short_path + "scalac_args")
  scalac_args = """{scala_opts} {plugin_arg} -classpath "{jars}" -d {out}_tmp {files}""".format(
      scala_opts=" ".join(ctx.attr.scalacopts),
      plugin_arg = plugin_arg,
      jars=":".join([j.path for j in jars]),
      files=" ".join([f.path for f in sources]),
      out=ctx.outputs.jar.path
      )
  ctx.file_action(output = scalac_args_file, content = scalac_args)

  srcjar_cmd = ""
  if len(all_srcjars) > 0:
    srcjar_cmd = "\nmkdir -p {out}_tmp_expand_srcjars\n"
    for srcjar in all_srcjars:
      # Note: this is double escaped because we need to do one format call
      # per each srcjar, but then we are going to include this in the bigger format
      # call that is done to generate the full command

      #TODO would like to be able to switch >/dev/null, -v, etc based on the user's settings
      srcjar_cmd += """
unzip -o {srcjar} -d {{out}}_tmp_expand_srcjars >/dev/null
""".format(srcjar = srcjar.path)
    srcjar_cmd += """find {out}_tmp_expand_srcjars -type f -name "*.scala" > {out}_args/files_from_jar\n"""

  cmd = """
rm -rf {out}_args
rm -rf {out}_tmp
rm -rf {out}_tmp_expand_srcjars
set -e
mkdir -p {out}_args
touch {out}_args/files_from_jar
mkdir -p {out}_tmp""" + srcjar_cmd + """
cat {scalac_args} {out}_args/files_from_jar > {out}_args/args
env JAVACMD={java} {scalac} {jvm_flags} @{out}_args/args
# Make jar file deterministic by setting the timestamp of files
find {out}_tmp -exec touch -t 198001010000 {{}} \;
touch -t 198001010000 {manifest}
echo {manifest} >> filelist.txt
pushd {out}_tmp
find . | sort | xargs -n 1 -IREPLACE echo REPLACE >> filelist.txt
touch -t 198001010000 filelist.txt
zip -X -q -FS out.jar -@ < filelist.txt
popd
mv {out}_tmp/out.jar {out}
rm -rf {out}_args
rm -rf {out}_tmp
rm -rf {out}_tmp_expand_srcjars
""" + ijar_cmd + res_cmd
  cmd = cmd.format(
      java=ctx.file._java.path,
      jvm_flags=" ".join(["-J" + flag for flag in ctx.attr.jvm_flags]),
      scalac=ctx.file._scalac.path,
      scalac_args=scalac_args_file.path,
      out=ctx.outputs.jar.path,
      manifest=ctx.outputs.manifest.path,
      jar=ctx.file._jar.path,
      ijar=ctx.file._ijar.path,
    )
  outs = [ctx.outputs.jar]
  if buildijar:
    outs.extend([ctx.outputs.ijar])
  ctx.action(
      inputs=list(jars) +
          list(dep_srcjars) +
          list(srcjars) +
          list(sources) +
          ctx.files.srcs +
          ctx.files.plugins +
          ctx.files.resources +
          ctx.files._jdk +
          ctx.files._scalasdk +
          [ctx.outputs.manifest,
            ctx.file._jar,
            ctx.file._ijar,
            ctx.file._scalac,
            scalac_args_file],
      outputs=outs,
      command=cmd,
      progress_message="scala %s" % ctx.label,
      arguments=[])

def _compile_or_empty(ctx, jars, srcjars, buildijar):
  # We assume that if a srcjar is present, it is not empty
  if len(ctx.files.srcs) + len(srcjars) == 0:
    _build_nosrc_jar(ctx, buildijar)
    #  no need to build ijar when empty
    return struct(ijar=ctx.outputs.jar, class_jar=ctx.outputs.jar)
  else:
    _compile(ctx, jars, srcjars, buildijar)
    ijar = None
    if buildijar:
      ijar = ctx.outputs.ijar
    else:
      #  macro code needs to be available at compile-time, so set ijar == jar
      ijar = ctx.outputs.jar
    return struct(ijar=ijar, class_jar=ctx.outputs.jar)

def write_manifest(ctx):
  # TODO(bazel-team): I don't think this classpath is what you want
  manifest = "Class-Path: %s\n" % ctx.file._scalalib.path
  if getattr(ctx.attr, "main_class", ""):
    manifest += "Main-Class: %s\n" % ctx.attr.main_class

  ctx.file_action(
      output = ctx.outputs.manifest,
      content = manifest)

def _write_launcher(ctx, jars):
  classpath = ':'.join(["$0.runfiles/" + f.short_path for f in jars])
  content = """#!/bin/bash
export CLASSPATH={classpath}
$0.runfiles/{java} {name} "$@"
""".format(
    java=ctx.file._java.path,
    name=ctx.attr.main_class,
    deploy_jar=ctx.outputs.jar.path,
    classpath=classpath,
  )
  ctx.file_action(
      output=ctx.outputs.executable,
      content=content)

def _write_test_launcher(ctx, jars):
  if len(ctx.attr.suites) != 0:
    print("suites attribute is deprecated. All scalatest test suites are run")

  content = """#!/bin/bash
{java} -cp {cp} {name} {args} -C io.bazel.rules.scala.JUnitXmlReporter "$@"
"""
  content = content.format(
      java=ctx.file._java.path,
      cp=":".join([j.short_path for j in jars]),
      name=ctx.attr.main_class,
      args="-R \"{path}\" -oWDF".format(path=ctx.outputs.jar.short_path))
  ctx.file_action(
      output=ctx.outputs.executable,
      content=content)

def collect_srcjars(targets):
  srcjars = set()
  for target in targets:
    if hasattr(target, "srcjars"):
      srcjars += [target.srcjars.srcjar]
  return srcjars

def _collect_jars(targets):
  """Compute the runtime and compile-time dependencies from the given targets"""
  compile_jars = set()
  runtime_jars = set()
  ijars = set()
  for target in targets:
    found = False
    if hasattr(target, "scala"):
      if hasattr(target.scala.outputs, "ijar"):
        compile_jars += [target.scala.outputs.ijar]
      compile_jars += target.scala.transitive_compile_exports
      runtime_jars += target.scala.transitive_runtime_deps
      runtime_jars += target.scala.transitive_runtime_exports
      found = True
    if hasattr(target, "java"):
      # see JavaSkylarkApiProvider.java, this is just the compile-time deps
      # this should be improved in bazel 0.1.5 to get outputs.ijar
      # compile_jars += [target.java.outputs.ijar]
      compile_jars += target.java.transitive_deps
      runtime_jars += target.java.transitive_runtime_deps
      found = True
    if not found:
      # support http_file pointed at a jar. http_jar uses ijar, which breaks scala macros
      runtime_jars += target.files
      compile_jars += target.files
  return struct(compiletime = compile_jars, runtime = runtime_jars)

def _lib(ctx, non_macro_lib):
  # This will be used to pick up srcjars from non-scala library
  # targets (like thrift code generation)
  srcjars = collect_srcjars(ctx.attr.deps)
  jars = _collect_jars(ctx.attr.deps)
  (cjars, rjars) = (jars.compiletime, jars.runtime)
  write_manifest(ctx)
  outputs = _compile_or_empty(ctx, cjars, srcjars, non_macro_lib)

  rjars += [ctx.outputs.jar]
  rjars += _collect_jars(ctx.attr.runtime_deps).runtime

  if not non_macro_lib:
    #  macros need the scala reflect jar
    rjars += [ctx.file._scalareflect]

  texp = _collect_jars(ctx.attr.exports)
  scalaattr = struct(outputs = outputs,
                     transitive_runtime_deps = rjars,
                     transitive_compile_exports = texp.compiletime + cjars,
                     transitive_runtime_exports = texp.runtime
                     )
  runfiles = ctx.runfiles(
      files = list(rjars),
      collect_data = True)
  return struct(
      scala = scalaattr,
      runfiles=runfiles,
      # This is a free monoid given to the graph for the purpose of
      # extensibility. This is necessary when one wants to create
      # new targets which want to leverage a scala_library. For example,
      # new_target1 -> scala_library -> new_target2. There might be
      # information that new_target2 needs to get from new_target1,
      # but we do not want to ohave to change scala_library to pass
      # this information through. extra_information allows passing
      # this information through, and it is up to the new_targets
      # to filter and make sense of this information.
      extra_information=_collect_extra_information(ctx.attr.deps),
    )

def _collect_extra_information(targets):
  r = []
  for target in targets:
    if hasattr(target, 'extra_information'):
      r.extend(target.extra_information)
  return r

def _scala_library_impl(ctx):
  return _lib(ctx, True)

def _scala_macro_library_impl(ctx):
  return _lib(ctx, False)  # don't build the ijar for macros

# Common code shared by all scala binary implementations.
def _scala_binary_common(ctx, cjars, rjars):
  write_manifest(ctx)
  _compile_or_empty(ctx, cjars, [], False)  # no need to build an ijar for an executable

  runfiles = ctx.runfiles(
      files = list(rjars) + [ctx.outputs.executable] + [ctx.file._java] + ctx.files._jdk,
      collect_data = True)
  return struct(
      files=set([ctx.outputs.executable]),
      runfiles=runfiles)

def _scala_binary_impl(ctx):
  jars = _collect_jars(ctx.attr.deps)
  (cjars, rjars) = (jars.compiletime, jars.runtime)
  cjars += [ctx.file._scalareflect]
  rjars += [ctx.outputs.jar, ctx.file._scalalib, ctx.file._scalareflect]
  rjars += _collect_jars(ctx.attr.runtime_deps).runtime
  _write_launcher(ctx, rjars)
  return _scala_binary_common(ctx, cjars, rjars)

def _scala_test_impl(ctx):
  deps = ctx.attr.deps
  deps += [ctx.attr._scalatest_reporter]
  jars = _collect_jars(deps)
  (cjars, rjars) = (jars.compiletime, jars.runtime)
  cjars += [ctx.file._scalareflect, ctx.file._scalatest, ctx.file._scalaxml]
  rjars += [ctx.outputs.jar, ctx.file._scalalib, ctx.file._scalareflect, ctx.file._scalatest, ctx.file._scalaxml]
  rjars += _collect_jars(ctx.attr.runtime_deps).runtime
  _write_test_launcher(ctx, rjars)
  return _scala_binary_common(ctx, cjars, rjars)

_implicit_deps = {
  "_ijar": attr.label(executable=True, default=Label("@bazel_tools//tools/jdk:ijar"), single_file=True, allow_files=True),
  "_scalac": attr.label(executable=True, default=Label("@scala//:bin/scalac"), single_file=True, allow_files=True),
  "_scalalib": attr.label(default=Label("@scala//:lib/scala-library.jar"), single_file=True, allow_files=True),
  "_scalaxml": attr.label(default=Label("@scala//:lib/scala-xml_2.11-1.0.4.jar"), single_file=True, allow_files=True),
  "_scalasdk": attr.label(default=Label("@scala//:sdk"), allow_files=True),
  "_scalareflect": attr.label(default=Label("@scala//:lib/scala-reflect.jar"), single_file=True, allow_files=True),
  "_java": attr.label(executable=True, default=Label("@bazel_tools//tools/jdk:java"), single_file=True, allow_files=True),
  "_jar": attr.label(executable=True, default=Label("@bazel_tools//tools/jdk:jar"), single_file=True, allow_files=True),
  "_jdk": attr.label(default=Label("//tools/defaults:jdk"), allow_files=True),
}

# Common attributes reused across multiple rules.
_common_attrs = {
  "srcs": attr.label_list(
      allow_files=_scala_srcjar_filetype),
  "deps": attr.label_list(),
  "plugins": attr.label_list(allow_files=_jar_filetype),
  "runtime_deps": attr.label_list(),
  "data": attr.label_list(allow_files=True, cfg=DATA_CFG),
  "resources": attr.label_list(allow_files=True),
  "scalacopts":attr.string_list(),
  "jvm_flags": attr.string_list(),
}

scala_library = rule(
  implementation=_scala_library_impl,
  attrs={
      "main_class": attr.string(),
      "exports": attr.label_list(allow_files=False),
      } + _implicit_deps + _common_attrs,
  outputs={
      "jar": "%{name}_deploy.jar",
      "ijar": "%{name}_ijar.jar",
      "manifest": "%{name}_MANIFEST.MF",
      },
)

scala_macro_library = rule(
  implementation=_scala_macro_library_impl,
  attrs={
      "main_class": attr.string(),
      "exports": attr.label_list(allow_files=False),
      } + _implicit_deps + _common_attrs,
  outputs={
      "jar": "%{name}_deploy.jar",
      "manifest": "%{name}_MANIFEST.MF",
      },
)

scala_binary = rule(
  implementation=_scala_binary_impl,
  attrs={
      "main_class": attr.string(mandatory=True),
      } + _implicit_deps + _common_attrs,
  outputs={
      "jar": "%{name}_deploy.jar",
      "manifest": "%{name}_MANIFEST.MF",
      },
  executable=True,
)

scala_test = rule(
  implementation=_scala_test_impl,
  attrs={
      "main_class": attr.string(default="org.scalatest.tools.Runner"),
      "suites": attr.string_list(),
      "_scalatest": attr.label(executable=True, default=Label("@scalatest//file"), single_file=True, allow_files=True),
      "_scalatest_reporter": attr.label(default=Label("//scala/support:test_reporter")),
      } + _implicit_deps + _common_attrs,
  outputs={
      "jar": "%{name}_deploy.jar",
      "manifest": "%{name}_MANIFEST.MF",
      },
  executable=True,
  test=True,
)

def scala_version():
  """return the scala version for use in maven coordinates"""
  return "2.11"

def scala_mvn_artifact(artifact):
  gav = artifact.split(":")
  groupid = gav[0]
  artifactid = gav[1]
  version = gav[2]
  return "%s:%s_%s:%s" % (groupid, artifactid, scala_version(), version)

SCALA_BUILD_FILE = """
# scala.BUILD
exports_files([
  "bin/scala",
  "bin/scalac",
  "bin/scaladoc",
  "lib/config-1.2.1.jar",
  "lib/jline-2.12.1.jar",
  "lib/scala-actors-2.11.0.jar",
  "lib/scala-actors-migration_2.11-1.1.0.jar",
  "lib/scala-compiler.jar",
  "lib/scala-continuations-library_2.11-1.0.2.jar",
  "lib/scala-continuations-plugin_2.11.8-1.0.2.jar",
  "lib/scala-library.jar",
  "lib/scala-parser-combinators_2.11-1.0.4.jar",
  "lib/scala-reflect.jar",
  "lib/scala-swing_2.11-1.0.2.jar",
  "lib/scala-xml_2.11-1.0.4.jar",
  "lib/scalap-2.11.8.jar",
])

filegroup(
    name = "sdk",
    # For some reason, the SDK zip contains a baked-in version of akka. We need
    # to explicitly exclude it here, otherwise the scala compiler will grab it
    # and put it on its classpath.
    srcs = glob(["**"], exclude=["lib/akka-actor_2.11-2.3.10.jar"]),
    visibility = ["//visibility:public"],
)
"""

def scala_repositories():
  native.new_http_archive(
    name = "scala",
    strip_prefix = "scala-2.11.8",
    sha256 = "87fc86a19d9725edb5fd9866c5ee9424cdb2cd86b767f1bb7d47313e8e391ace",
    url = "https://downloads.typesafe.com/scala/2.11.8/scala-2.11.8.tgz",
    build_file_content = SCALA_BUILD_FILE,
  )
  native.http_file(
    name = "scalatest",
    url = "https://oss.sonatype.org/content/groups/public/org/scalatest/scalatest_2.11/2.2.6/scalatest_2.11-2.2.6.jar",
    sha256 = "f198967436a5e7a69cfd182902adcfbcb9f2e41b349e1a5c8881a2407f615962",
  )

def scala_export_to_java(name, exports, runtime_deps):
  jars = []
  for target in exports:
    jars.append("{}_deploy.jar".format(target))

  native.java_import(
    name = name,
    # these are the outputs of the scala_library targets
    jars = jars,
    runtime_deps = ["@scala//:lib/scala-library.jar"] + runtime_deps
  )
