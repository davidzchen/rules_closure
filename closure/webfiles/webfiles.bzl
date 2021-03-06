# Copyright 2016 The Closure Rules Authors. All rights reserved.
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

"""Web component validation, packaging, and development web server."""

load("//closure/private:defs.bzl",
     "create_argfile",
     "difference",
     "long_path",
     "unfurl")

def _webfiles(ctx):
  # additional preconditions
  if not ctx.attr.path.startswith("/"):
    fail("webpath must start with /")
  if ctx.attr.path != "/" and ctx.attr.path.endswith("/"):
    fail("webpath must not end with / unless it is /")
  if "//" in ctx.attr.path:
    fail("webpath must not have //")

  # process what came before
  deps = unfurl(ctx.attr.deps, provider="webfiles")
  webpaths = set()
  manifests = set(order="link")
  for dep in deps:
    webpaths += dep.webfiles.webpaths
    manifests += dep.webfiles.manifests

  # process what comes now
  new_webpaths = []
  manifest_srcs = []
  for src in ctx.attr.srcs:
    sname = "/" + src.label.name
    for srcfile in src.files:
      if srcfile.path.endswith(sname) or srcfile.path == src.label.name:
        name = src.label.name
      else:
        name = srcfile.basename
      webpath = "%s/%s" % ("" if ctx.attr.path == "/" else ctx.attr.path, name)
      if webpath in new_webpaths:
        fail("name collision in srcs: " + name)
      if webpath in webpaths:
        fail("webpath already defined by child rules: " + webpath)
      new_webpaths.append(webpath)
      manifest_srcs.append(struct(
          path=srcfile.path,
          longpath=long_path(ctx, srcfile),
          webpath=webpath))
  webpaths += new_webpaths
  manifest = ctx.new_file(ctx.configuration.bin_dir, "%s.pbtxt" % ctx.label.name)
  ctx.file_action(
      output=manifest,
      content=struct(
          label=str(ctx.label),
          src=manifest_srcs).to_proto())
  manifests += [manifest]

  # perform strict dependency checking
  inputs = [manifest]
  direct_manifests = set([manifest])
  args = ["WebfilesValidator",
          "--dummy", ctx.outputs.dummy.path,
          "--target", manifest.path]
  inputs.extend(ctx.files.srcs)
  for dep in deps:
    inputs.append(dep.webfiles.dummy)
    for f in dep.files:
      inputs.append(f)
    direct_manifests += [dep.webfiles.manifest]
    inputs.append(dep.webfiles.manifest)
    args.append("--direct_dep")
    args.append(dep.webfiles.manifest.path)
  for man in difference(manifests, direct_manifests):
    inputs.append(man)
    args.append("--transitive_dep")
    args.append(man.path)
  argfile = create_argfile(ctx, args)
  inputs.append(argfile)
  ctx.action(
      inputs=inputs,
      outputs=[ctx.outputs.dummy],
      executable=ctx.executable._ClosureUberAlles,
      arguments=["@@" + argfile.path],
      mnemonic="Closure",
      execution_requirements={"supports-workers": "1"},
      progress_message="Checking %d web files" % len(ctx.files.srcs))

  # define development web server that only applies to this transitive closure
  args = ["#!/bin/sh\nexec " + ctx.executable._WebfilesServer.short_path]
  args.append("--label")
  args.append(ctx.label)
  for man in manifests:
    args.append("--manifest")
    args.append(man.short_path)
  args.append("\"$@\"")
  ctx.file_action(
      executable=True,
      output=ctx.outputs.executable,
      content=" \\\n  ".join(args))

  # export data to parent rules
  return struct(
      files=set([ctx.outputs.executable, ctx.outputs.dummy]),
      exports=unfurl(ctx.attr.exports),
      webfiles=struct(
          manifest=manifest,
          manifests=manifests,
          webpaths=webpaths,
          dummy=ctx.outputs.dummy),
      runfiles=ctx.runfiles(
          files=ctx.files.srcs + ctx.files.data + [manifest,
                                                   ctx.outputs.executable,
                                                   ctx.outputs.dummy],
          transitive_files=ctx.attr._WebfilesServer.data_runfiles.files,
          collect_data=True))

webfiles = rule(
    implementation=_webfiles,
    executable=True,
    attrs={
        "path": attr.string(mandatory=True),
        "srcs": attr.label_list(allow_files=True, mandatory=True),
        "deps": attr.label_list(providers=["webfiles"]),
        "exports": attr.label_list(),
        "data": attr.label_list(cfg="data", allow_files=True),
        "_ClosureUberAlles": attr.label(
            default=Label("//java/io/bazel/rules/closure:ClosureUberAlles"),
            executable=True,
            cfg="host"),
        "_WebfilesServer": attr.label(
            default=Label(
                "//java/io/bazel/rules/closure/webfiles/server"),
            executable=True,
            cfg="host"),
    },
    outputs={
        "dummy": "%{name}.ignoreme",
    })
