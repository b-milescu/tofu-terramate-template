# Project-wide globals. Directories below add to or override them (stacks/<environment>/globals.tm.hcl: vsphere_server).
globals {
  # Prefix of the VM folder <project>-<environment>. The RUNBOOK sets it.
  project                  = "example"
  opentofu_version         = ">= 1.12"
  vsphere_provider_version = ">= 2.17, < 3.0"

  # The folder names of stacks/<environment>/<datacenter>/<stack>. A datacenter whose vSphere name is not a usable folder
  # name (one with a space, say) sets datacenter = "<vSphere name>" in stacks/<environment>/<datacenter>/globals.tm.hcl.
  environment = tm_split("/", terramate.stack.path.relative)[1]
  datacenter  = tm_split("/", terramate.stack.path.relative)[2]

  # GitLab-managed OpenTofu state: one state per stack, named by its stack id, in this GitLab project. The numeric id
  # survives a project rename (a path-form address fails writes with 405 after one); a transfer was not tried.
  gitlab_url        = "https://gitlab.example.com"
  gitlab_project_id = "1111111111"

  # true adds a destroy guard to every stack of an environment (set in stacks/<environment>/globals.tm.hcl).
  protect_destroy = false

  # false verifies the vCenter's certificate; true skips the check for a lab whose vCenter certificate comes from a CA that no
  # operator machine trusts. Set it per environment in stacks/<environment>/globals.tm.hcl, only in a reviewed change.
  vsphere_allow_unverified_ssl = false

  # Non-vSphere providers of a stack, merged into its generated required_providers; a stack sets them in its own
  # globals.tm.hcl as { <name> = { source = "<namespace>/<name>", version = "<constraint>" } }. Credentials come from
  # each provider's environment variables only.
  extra_providers = {}
}
