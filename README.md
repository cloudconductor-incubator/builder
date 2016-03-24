# Builder

Builder is a toolset to provision your own systems on AWS and on_premise servers.

# Usage

Clone the repository and do `bundle install`.

```bash
$ cd /path/to/cloned/builder
$ bundle install --path vendor/bundle --standalone
```

Create a working directory.

```bash
$ mkdir -p /path/to/builder/work_dir
$ cd /path/to/builder/work_dir
```

Initialize Builder.

```bash
$ PATH=/path/to/cloned/builder/bin:$PATH
$ builder init
```

`builder init` generates the following files:
 - `builder.yml`
 - `.builder`

Edit the files then hit the next line.

```bash
$ builder up
```
