terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Get operator IP automatically
data "http" "operator_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  operator_cidr = var.operator_ip != "" ? var.operator_ip : "${chomp(data.http.operator_ip.response_body)}/32"
  labels = {
    project     = "avalanche-l1"
    environment = var.environment
    managed-by  = "terraform"
  }
}

#
# NETWORKING
#

resource "google_compute_network" "main" {
  name                    = "${var.name_prefix}-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "${var.name_prefix}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.main.id
}

#
# FIREWALL RULES
#

resource "google_compute_firewall" "ssh" {
  name    = "${var.name_prefix}-allow-ssh"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [local.operator_cidr]
  target_tags   = ["avalanche-node"]
}

resource "google_compute_firewall" "avalanche_api" {
  name    = "${var.name_prefix}-allow-api"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["9650"]
  }

  source_ranges = [local.operator_cidr]
  target_tags   = ["avalanche-node"]
}

resource "google_compute_firewall" "avalanche_p2p" {
  name    = "${var.name_prefix}-allow-p2p"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["9651"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["avalanche-node"]
}

resource "google_compute_firewall" "internal" {
  name    = "${var.name_prefix}-allow-internal"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["9650", "9651"]
  }

  source_tags = ["avalanche-node"]
  target_tags = ["avalanche-node"]
}

resource "google_compute_firewall" "grafana" {
  name    = "${var.name_prefix}-allow-grafana"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["3000"]
  }

  source_ranges = var.enable_public_grafana ? ["0.0.0.0/0"] : [local.operator_cidr]
  target_tags   = ["grafana"]
}

resource "google_compute_firewall" "rpc_public" {
  count   = var.enable_public_rpc ? 1 : 0
  name    = "${var.name_prefix}-allow-rpc-public"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["9650"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["avalanche-rpc"]
}

#
# COMPUTE INSTANCES - VALIDATORS
#

resource "google_compute_instance" "validators" {
  count = var.validator_count

  name         = "${var.name_prefix}-validator-${count.index + 1}"
  machine_type = var.validator_machine_type
  zone         = var.zones[count.index % length(var.zones)]

  tags = count.index == 0 ? ["avalanche-node", "grafana"] : ["avalanche-node"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_size_gb
      type  = "pd-ssd"
    }
  }

  network_interface {
    network    = google_compute_network.main.name
    subnetwork = google_compute_subnetwork.main.name

    access_config {
      // Ephemeral public IP
    }
  }

  metadata = {
    ssh-keys = var.ssh_user != "" && var.ssh_public_key != "" ? "${var.ssh_user}:${var.ssh_public_key}" : null
  }

  labels = merge(local.labels, {
    role = "validator"
  })

  service_account {
    scopes = ["cloud-platform"]
  }
}

#
# COMPUTE INSTANCES - RPC NODES
#

resource "google_compute_instance" "rpc" {
  count = var.rpc_count

  name         = "${var.name_prefix}-rpc-${count.index + 1}"
  machine_type = var.rpc_machine_type
  zone         = var.zones[count.index % length(var.zones)]

  tags = ["avalanche-node", "avalanche-rpc"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_size_gb
      type  = "pd-ssd"
    }
  }

  network_interface {
    network    = google_compute_network.main.name
    subnetwork = google_compute_subnetwork.main.name

    access_config {
      // Ephemeral public IP
    }
  }

  metadata = {
    ssh-keys = var.ssh_user != "" && var.ssh_public_key != "" ? "${var.ssh_user}:${var.ssh_public_key}" : null
  }

  labels = merge(local.labels, {
    role = "rpc"
  })

  service_account {
    scopes = ["cloud-platform"]
  }
}
