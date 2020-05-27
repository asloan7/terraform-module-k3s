// - Agent metadata cache
locals {
  agent_annotations_list = flatten([
    for nk, nv in var.agents : [
      // Because we need node name and annotation name when we remove the annotation resource, we need
      // to share them through the annotation key (each.value are not avaible on destruction).
      for ak, av in try(nv.annotations, {}) : av == null ? { key : "" } : { key : "${nk}${var.separator}${ak}", value : av }
    ]
  ])
  agent_annotations = contains(var.enabled_managed_fields, "annotation") ? { for o in local.agent_annotations_list : o.key => o.value if o.key != "" } : {}

  agent_labels_list = flatten([
    for nk, nv in var.agents : [
      // Because we need node name and label name when we remove the label resource, we need
      // to share them through the label key (each.value are not avaible on destruction).
      for lk, lv in try(nv.labels, {}) : lv == null ? { key : "" } : { key : "${nk}${var.separator}${lk}", value : lv }
    ]
  ])
  agent_labels = contains(var.enabled_managed_fields, "label") ? { for o in local.agent_labels_list : o.key => o.value if o.key != "" } : {}

  agent_taints_list = flatten([
    for nk, nv in var.agents : [
      // Because we need node name and taint name when we remove the taint resource, we need
      // to share them through the taint key (each.value are not avaible on destruction).
      for tk, tv in try(nv.taints, {}) : tv == null ? { key : "" } : { key : "${nk}${var.separator}${tk}", value : tv }
    ]
  ])
  agent_taints = contains(var.enabled_managed_fields, "taint") ? { for o in local.agent_taints_list : o.key => o.value if o.key != "" } : {}
}

data null_data_source agents_metadata {
  for_each = var.agents

  inputs = {
    name = try(each.value.name, each.key)
    ip   = each.value.ip

    flags = join(" ", compact(concat(
      [
        "--node-ip ${each.value.ip}",
        "--node-name '${try(each.value.name, each.key)}'",
        "--server https://${local.root_server_ip}:6443",
        "--token ${random_password.k3s_cluster_secret.result}",
      ],
      var.global_flags,
      try(each.value.flags, []),
      [for key, value in try(each.value.labels, {}) : "--node-label '${key}=${value}'" if value != null],
      [for key, value in try(each.value.taints, {}) : "--node-taint '${key}=${value}'" if value != null]
    )))

    immutable_fields_hash = sha1(join("", concat(
      [var.name, var.cidr.pods, var.cidr.services],
      var.global_flags,
      try(each.value.flags, []),
    )))
  }
}

// - Agent installation
resource null_resource k3s_agents_install {
  for_each = var.agents
  triggers = {
    on_immutable_fields_changes = data.null_data_source.agents_metadata[each.key].outputs.immutable_fields_hash
  }

  connection {
    type = try(each.value.connection.type, "ssh")

    host     = try(each.value.connection.host, each.value.ip)
    user     = try(each.value.connection.user, null)
    password = try(each.value.connection.password, null)
    port     = try(each.value.connection.port, null)
    timeout  = try(each.value.connection.timeout, null)

    script_path    = try(each.value.connection.script_path, null)
    private_key    = try(each.value.connection.private_key, null)
    certificate    = try(each.value.connection.certificate, null)
    agent          = try(each.value.connection.agent, null)
    agent_identity = try(each.value.connection.agent_identity, null)
    host_key       = try(each.value.connection.host_key, null)

    https    = try(each.value.connection.https, null)
    insecure = try(each.value.connection.insecure, null)
    use_ntlm = try(each.value.connection.use_ntlm, null)
    cacert   = try(each.value.connection.cacert, null)

    bastion_host        = try(each.value.connection.bastion_host, null)
    bastion_host_key    = try(each.value.connection.bastion_host_key, null)
    bastion_port        = try(each.value.connection.bastion_port, null)
    bastion_user        = try(each.value.connection.bastion_user, null)
    bastion_password    = try(each.value.connection.bastion_password, null)
    bastion_private_key = try(each.value.connection.bastion_private_key, null)
    bastion_certificate = try(each.value.connection.bastion_certificate, null)
  }

  # Upload k3s file
  provisioner file {
    content     = data.http.k3s_installer.body
    destination = "/tmp/k3s-installer"
  }

  # Remove old k3s installation
  provisioner remote-exec {
    inline = [
      "if ! command -V k3s-agent-uninstall.sh > /dev/null; then exit; fi",
      "echo >&2 [WARN] K3s seems already installed on this node and will be uninstalled.",
      "k3s-agent-uninstall.sh",
    ]
  }

  # Install k3s server
  provisioner "remote-exec" {
    inline = [
      "INSTALL_K3S_VERSION=${local.k3s_version} sh /tmp/k3s-installer ${data.null_data_source.agents_metadata[each.key].outputs.flags}",
      "until kubectl get nodes | grep -v '[WARN] No resources found'; do sleep 1; done"
    ]
  }
}

# - Agent annotation, label and taint management
# Add manually annotation on k3s agent (not updated when k3s restart with new annotations)
resource null_resource k3s_agents_annotation {
  for_each = local.agent_annotations

  depends_on = [null_resource.k3s_agents_install]
  triggers = {
    agent_name       = split(var.separator, each.key)[0]
    annotation_name  = split(var.separator, each.key)[1]
    on_install       = null_resource.k3s_agents_install[split(var.separator, each.key)[0]].id
    on_value_changes = each.value
  }

  connection {
    type = try(var.agents[split(var.separator, each.key)[0]].connection.type, "ssh")

    host     = try(var.agents[split(var.separator, each.key)[0]].connection.host, data.null_data_source.agents_metadata[split(var.separator, each.key)[0]].outputs.ip)
    user     = try(var.agents[split(var.separator, each.key)[0]].connection.user, null)
    password = try(var.agents[split(var.separator, each.key)[0]].connection.password, null)
    port     = try(var.agents[split(var.separator, each.key)[0]].connection.port, null)
    timeout  = try(var.agents[split(var.separator, each.key)[0]].connection.timeout, null)

    script_path    = try(var.agents[split(var.separator, each.key)[0]].connection.script_path, null)
    private_key    = try(var.agents[split(var.separator, each.key)[0]].connection.private_key, null)
    certificate    = try(var.agents[split(var.separator, each.key)[0]].connection.certificate, null)
    agent          = try(var.agents[split(var.separator, each.key)[0]].connection.agent, null)
    agent_identity = try(var.agents[split(var.separator, each.key)[0]].connection.agent_identity, null)
    host_key       = try(var.agents[split(var.separator, each.key)[0]].connection.host_key, null)

    https    = try(var.agents[split(var.separator, each.key)[0]].connection.https, null)
    insecure = try(var.agents[split(var.separator, each.key)[0]].connection.insecure, null)
    use_ntlm = try(var.agents[split(var.separator, each.key)[0]].connection.use_ntlm, null)
    cacert   = try(var.agents[split(var.separator, each.key)[0]].connection.cacert, null)

    bastion_host        = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_host, null)
    bastion_host_key    = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_host_key, null)
    bastion_port        = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_port, null)
    bastion_user        = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_user, null)
    bastion_password    = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_password, null)
    bastion_private_key = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_private_key, null)
    bastion_certificate = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_certificate, null)
  }

  provisioner remote-exec {
    inline = [
    "kubectl annotate --overwrite node ${data.null_data_source.agents_metadata[split(var.separator, each.key)[0]].outputs.name} ${split(var.separator, each.key)[1]}=${each.value}"]
  }

  provisioner remote-exec {
    when = destroy
    inline = [
    "kubectl annotate node ${data.null_data_source.agents_metadata[split(var.separator, each.key)[0]].outputs.name} ${split(var.separator, each.key)[1]}-"]
  }
}

# Add manually label on k3s agent (not updated when k3s restart with new labels)
resource null_resource k3s_agents_label {
  for_each = local.agent_labels

  depends_on = [null_resource.k3s_agents_install]
  triggers = {
    agent_name       = split(var.separator, each.key)[0]
    label_name       = split(var.separator, each.key)[1]
    on_install       = null_resource.k3s_agents_install[split(var.separator, each.key)[0]].id
    on_value_changes = each.value
  }

  connection {
    type = try(var.agents[split(var.separator, each.key)[0]].connection.type, "ssh")

    host     = try(var.agents[split(var.separator, each.key)[0]].connection.host, data.null_data_source.agents_metadata[split(var.separator, each.key)[0]].outputs.ip)
    user     = try(var.agents[split(var.separator, each.key)[0]].connection.user, null)
    password = try(var.agents[split(var.separator, each.key)[0]].connection.password, null)
    port     = try(var.agents[split(var.separator, each.key)[0]].connection.port, null)
    timeout  = try(var.agents[split(var.separator, each.key)[0]].connection.timeout, null)

    script_path    = try(var.agents[split(var.separator, each.key)[0]].connection.script_path, null)
    private_key    = try(var.agents[split(var.separator, each.key)[0]].connection.private_key, null)
    certificate    = try(var.agents[split(var.separator, each.key)[0]].connection.certificate, null)
    agent          = try(var.agents[split(var.separator, each.key)[0]].connection.agent, null)
    agent_identity = try(var.agents[split(var.separator, each.key)[0]].connection.agent_identity, null)
    host_key       = try(var.agents[split(var.separator, each.key)[0]].connection.host_key, null)

    https    = try(var.agents[split(var.separator, each.key)[0]].connection.https, null)
    insecure = try(var.agents[split(var.separator, each.key)[0]].connection.insecure, null)
    use_ntlm = try(var.agents[split(var.separator, each.key)[0]].connection.use_ntlm, null)
    cacert   = try(var.agents[split(var.separator, each.key)[0]].connection.cacert, null)

    bastion_host        = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_host, null)
    bastion_host_key    = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_host_key, null)
    bastion_port        = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_port, null)
    bastion_user        = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_user, null)
    bastion_password    = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_password, null)
    bastion_private_key = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_private_key, null)
    bastion_certificate = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_certificate, null)
  }

  provisioner remote-exec {
    inline = [
    "kubectl label --overwrite node ${data.null_data_source.agents_metadata[split(var.separator, each.key)[0]].outputs.name} ${split(var.separator, each.key)[1]}=${each.value}"]
  }

  provisioner remote-exec {
    when = destroy
    inline = [
    "kubectl label node ${data.null_data_source.agents_metadata[split(var.separator, each.key)[0]].outputs.name} ${split(var.separator, each.key)[1]}-"]
  }
}

# Add manually taint on k3s agent (not updated when k3s restart with new taints)
resource null_resource k3s_agents_taint {
  for_each = local.agent_taints

  depends_on = [null_resource.k3s_agents_install]
  triggers = {
    agent_name       = split(var.separator, each.key)[0]
    taint_name       = split(var.separator, each.key)[1]
    on_install       = null_resource.k3s_agents_install[split(var.separator, each.key)[0]].id
    on_value_changes = each.value
  }

  connection {
    type = try(var.agents[split(var.separator, each.key)[0]].connection.type, "ssh")

    host     = try(var.agents[split(var.separator, each.key)[0]].connection.host, data.null_data_source.agents_metadata[split(var.separator, each.key)[0]].outputs.ip)
    user     = try(var.agents[split(var.separator, each.key)[0]].connection.user, null)
    password = try(var.agents[split(var.separator, each.key)[0]].connection.password, null)
    port     = try(var.agents[split(var.separator, each.key)[0]].connection.port, null)
    timeout  = try(var.agents[split(var.separator, each.key)[0]].connection.timeout, null)

    script_path    = try(var.agents[split(var.separator, each.key)[0]].connection.script_path, null)
    private_key    = try(var.agents[split(var.separator, each.key)[0]].connection.private_key, null)
    certificate    = try(var.agents[split(var.separator, each.key)[0]].connection.certificate, null)
    agent          = try(var.agents[split(var.separator, each.key)[0]].connection.agent, null)
    agent_identity = try(var.agents[split(var.separator, each.key)[0]].connection.agent_identity, null)
    host_key       = try(var.agents[split(var.separator, each.key)[0]].connection.host_key, null)

    https    = try(var.agents[split(var.separator, each.key)[0]].connection.https, null)
    insecure = try(var.agents[split(var.separator, each.key)[0]].connection.insecure, null)
    use_ntlm = try(var.agents[split(var.separator, each.key)[0]].connection.use_ntlm, null)
    cacert   = try(var.agents[split(var.separator, each.key)[0]].connection.cacert, null)

    bastion_host        = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_host, null)
    bastion_host_key    = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_host_key, null)
    bastion_port        = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_port, null)
    bastion_user        = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_user, null)
    bastion_password    = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_password, null)
    bastion_private_key = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_private_key, null)
    bastion_certificate = try(var.agents[split(var.separator, each.key)[0]].connection.bastion_certificate, null)
  }

  provisioner remote-exec {
    inline = [
    "kubectl taint node ${data.null_data_source.agents_metadata[split(var.separator, each.key)[0]].outputs.name} ${split(var.separator, each.key)[1]}=${each.value} --overwrite"]
  }

  provisioner remote-exec {
    when = destroy
    inline = [
    "kubectl taint node ${data.null_data_source.agents_metadata[split(var.separator, each.key)[0]].outputs.name} ${split(var.separator, each.key)[1]}-"]
  }
}
