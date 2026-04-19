# Guide: Creating a Wazuh Internal Health Dashboard

This guide outlines the steps to create a custom dashboard in Wazuh to monitor the health and performance of the SIEM platform itself. This helps separate platform issues (like log ingestion problems) from security event analysis.

### Step 1: Create a New Dashboard

1.  Navigate to the **Dashboards** section in the Wazuh UI.
2.  Click **Create dashboard**.
3.  Give it a name, such as "Wazuh Internal Health".

### Step 2: Create Visualizations for Key Metrics

For each of the following metrics, you will create a new visualization and add it to your dashboard.

#### Visualization 1: "Too Big Message Size" Errors

This panel will help you track the `wazuh-remoted` errors related to log spam.

1.  **Create New Visualization:** Choose "Lens" or "Aggregation-based". A Vertical Bar chart is a good choice.
2.  **Index Pattern:** Select `wazuh-alerts-*`.
3.  **Metrics:**
    *   Y-axis: **Count** of documents.
4.  **Buckets (X-axis):**
    *   **Date Histogram** aggregation on the `@timestamp` field.
5.  **Filter:**
    *   Add a filter where `rule.description` is exactly `"wazuh-remoted: WARNING: Too big message size from socket"`.
6.  **Save** the visualization with a descriptive name (e.g., "Remoted 'Too Big' Errors Over Time") and add it to your "Wazuh Internal Health" dashboard.

#### Visualization 2: Index Pattern Version Conflicts

This panel tracks errors during the creation of index patterns, which can indicate a problem with startup or configuration.

1.  **Create New Visualization:** A "Data Table" is suitable here.
2.  **Index Pattern:** Select `wazuh-alerts-*`.
3.  **Metrics:**
    *   **Count** of documents.
4.  **Buckets (Rows):**
    *   **Terms** aggregation on `rule.description`.
5.  **Filter:**
    *   Add a filter where `rule.description` contains `"version conflict"`.
6.  **Save** the visualization (e.g., "Index Pattern Version Conflicts") and add it to your dashboard.

#### Visualization 3: Indexer/Manager Resource Usage

This requires metrics from the hosts. Assuming you have a metrics agent (like Metricbeat or the Prometheus node exporter) sending data to your observability stack (in this case, Prometheus, visualized in Grafana).

**Note:** This visualization is best created in your **Grafana** "Platform Health" dashboard, not in Wazuh, as Wazuh is not the primary metrics store.

*   **In Grafana:**
    1.  Go to your "Platform Health" dashboard.
    2.  Add a new panel.
    3.  Use your Prometheus datasource.
    4.  Use PromQL queries to visualize CPU and Memory for the `wazuh-indexer` and `wazuh-manager` containers.
        *   **CPU:** `rate(container_cpu_usage_seconds_total{name=~"wazuh-indexer|wazuh-manager"}[5m])`
        *   **Memory:** `container_memory_usage_bytes{name=~"wazuh-indexer|wazuh-manager"}`
    5.  Save this panel to your Grafana dashboard.

### Step 3: Arrange Your Dashboard

Organize the visualizations on your new "Wazuh Internal Health" dashboard for a clear and concise view of the platform's status.
