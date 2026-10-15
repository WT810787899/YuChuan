use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// ============================================================
// Data Models
// ============================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: String,
    pub name: String,
    pub email: String,
    pub role: UserRole,
    pub avatar_color: u32,
    pub is_active: bool,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum UserRole {
    Admin,
    Editor,
    Viewer,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DashboardStats {
    pub total_users: i32,
    pub active_users: i32,
    pub total_revenue: f64,
    pub growth_rate: f64,
    pub chart_data: Vec<ChartPoint>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChartPoint {
    pub label: String,
    pub value: f64,
    pub color: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Notification {
    pub id: String,
    pub title: String,
    pub message: String,
    pub notification_type: NotificationType,
    pub timestamp: String,
    pub is_read: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum NotificationType {
    Info,
    Success,
    Warning,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Product {
    pub id: String,
    pub name: String,
    pub category: String,
    pub price: f64,
    pub stock: i32,
    pub rating: f64,
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivityLog {
    pub id: String,
    pub user: String,
    pub action: String,
    pub target: String,
    pub timestamp: String,
    pub severity: Severity,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Severity {
    Low,
    Medium,
    High,
    Critical,
}

// ============================================================
// API Functions exposed to Flutter
// ============================================================

pub fn get_dashboard_stats() -> DashboardStats {
    DashboardStats {
        total_users: 1247,
        active_users: 892,
        total_revenue: 48750.0,
        growth_rate: 12.5,
        chart_data: vec![
            ChartPoint { label: "Jan".to_string(), value: 3200.0, color: 0xFF6366F1 },
            ChartPoint { label: "Feb".to_string(), value: 4100.0, color: 0xFF8B5CF6 },
            ChartPoint { label: "Mar".to_string(), value: 3800.0, color: 0xFFA78BFA },
            ChartPoint { label: "Apr".to_string(), value: 5200.0, color: 0xFF6366F1 },
            ChartPoint { label: "May".to_string(), value: 4800.0, color: 0xFF8B5CF6 },
            ChartPoint { label: "Jun".to_string(), value: 6100.0, color: 0xFFA78BFA },
            ChartPoint { label: "Jul".to_string(), value: 5800.0, color: 0xFF6366F1 },
            ChartPoint { label: "Aug".to_string(), value: 7200.0, color: 0xFF8B5CF6 },
        ],
    }
}

pub fn get_users() -> Vec<User> {
    vec![
        User {
            id: "1".to_string(),
            name: "Alice Chen".to_string(),
            email: "alice@example.com".to_string(),
            role: UserRole::Admin,
            avatar_color: 0xFF6366F1,
            is_active: true,
            created_at: "2024-01-15".to_string(),
        },
        User {
            id: "2".to_string(),
            name: "Bob Smith".to_string(),
            email: "bob@example.com".to_string(),
            role: UserRole::Editor,
            avatar_color: 0xFF10B981,
            is_active: true,
            created_at: "2024-02-20".to_string(),
        },
        User {
            id: "3".to_string(),
            name: "Carol Davis".to_string(),
            email: "carol@example.com".to_string(),
            role: UserRole::Viewer,
            avatar_color: 0xFFF59E0B,
            is_active: false,
            created_at: "2024-03-10".to_string(),
        },
        User {
            id: "4".to_string(),
            name: "David Lee".to_string(),
            email: "david@example.com".to_string(),
            role: UserRole::Editor,
            avatar_color: 0xFFEF4444,
            is_active: true,
            created_at: "2024-04-05".to_string(),
        },
        User {
            id: "5".to_string(),
            name: "Eva Martinez".to_string(),
            email: "eva@example.com".to_string(),
            role: UserRole::Admin,
            avatar_color: 0xFF8B5CF6,
            is_active: true,
            created_at: "2024-05-12".to_string(),
        },
    ]
}

pub fn get_notifications() -> Vec<Notification> {
    vec![
        Notification {
            id: "1".to_string(),
            title: "New user registered".to_string(),
            message: "Alice Chen has joined the platform".to_string(),
            notification_type: NotificationType::Success,
            timestamp: "2 min ago".to_string(),
            is_read: false,
        },
        Notification {
            id: "2".to_string(),
            title: "Server alert".to_string(),
            message: "CPU usage exceeded 85% on server-03".to_string(),
            notification_type: NotificationType::Warning,
            timestamp: "15 min ago".to_string(),
            is_read: false,
        },
        Notification {
            id: "3".to_string(),
            title: "Payment received".to_string(),
            message: "Invoice #1042 has been paid ($1,250.00)".to_string(),
            notification_type: NotificationType::Info,
            timestamp: "1 hour ago".to_string(),
            is_read: true,
        },
        Notification {
            id: "4".to_string(),
            title: "Deployment failed".to_string(),
            message: "Build #384 failed on production branch".to_string(),
            notification_type: NotificationType::Error,
            timestamp: "3 hours ago".to_string(),
            is_read: true,
        },
    ]
}

pub fn get_products() -> Vec<Product> {
    vec![
        Product {
            id: "1".to_string(),
            name: "Wireless Headphones".to_string(),
            category: "Electronics".to_string(),
            price: 129.99,
            stock: 45,
            rating: 4.5,
            tags: vec!["wireless".to_string(), "audio".to_string(), "bluetooth".to_string()],
        },
        Product {
            id: "2".to_string(),
            name: "Mechanical Keyboard".to_string(),
            category: "Electronics".to_string(),
            price: 89.99,
            stock: 23,
            rating: 4.8,
            tags: vec!["mechanical".to_string(), "gaming".to_string(), "rgb".to_string()],
        },
        Product {
            id: "3".to_string(),
            name: "USB-C Hub".to_string(),
            category: "Accessories".to_string(),
            price: 49.99,
            stock: 67,
            rating: 4.2,
            tags: vec!["usb-c".to_string(), "hub".to_string(), "multiport".to_string()],
        },
        Product {
            id: "4".to_string(),
            name: "4K Monitor".to_string(),
            category: "Electronics".to_string(),
            price: 399.99,
            stock: 12,
            rating: 4.7,
            tags: vec!["4k".to_string(), "monitor".to_string(), "display".to_string()],
        },
        Product {
            id: "5".to_string(),
            name: "Laptop Stand".to_string(),
            category: "Accessories".to_string(),
            price: 34.99,
            stock: 89,
            rating: 4.3,
            tags: vec!["ergonomic".to_string(), "aluminum".to_string(), "adjustable".to_string()],
        },
    ]
}

pub fn get_activity_logs() -> Vec<ActivityLog> {
    vec![
        ActivityLog {
            id: "1".to_string(),
            user: "Alice Chen".to_string(),
            action: "Created new project".to_string(),
            target: "Marketing Dashboard".to_string(),
            timestamp: "10:30 AM".to_string(),
            severity: Severity::Low,
        },
        ActivityLog {
            id: "2".to_string(),
            user: "Bob Smith".to_string(),
            action: "Modified user permissions".to_string(),
            target: "User: Carol Davis".to_string(),
            timestamp: "09:45 AM".to_string(),
            severity: Severity::Medium,
        },
        ActivityLog {
            id: "3".to_string(),
            user: "System".to_string(),
            action: "Database backup completed".to_string(),
            target: "production-db".to_string(),
            timestamp: "08:00 AM".to_string(),
            severity: Severity::Low,
        },
        ActivityLog {
            id: "4".to_string(),
            user: "David Lee".to_string(),
            action: "Deleted API key".to_string(),
            target: "sk-live-***".to_string(),
            timestamp: "Yesterday".to_string(),
            severity: Severity::High,
        },
        ActivityLog {
            id: "5".to_string(),
            user: "Eva Martinez".to_string(),
            action: "Exported user data".to_string(),
            target: "users.csv (2.3 MB)".to_string(),
            timestamp: "Yesterday".to_string(),
            severity: Severity::Medium,
        },
    ]
}

pub fn search_users(query: String) -> Vec<User> {
    let all_users = get_users();
    if query.is_empty() {
        return all_users;
    }
    all_users
        .into_iter()
        .filter(|u| {
            u.name.to_lowercase().contains(&query.to_lowercase())
                || u.email.to_lowercase().contains(&query.to_lowercase())
        })
        .collect()
}

pub fn calculate_revenue(months: i32) -> f64 {
    let base = 48750.0;
    let growth = 1.125_f64;
    base * growth.powi(months / 3)
}

pub fn get_system_health() -> HashMap<String, String> {
    let mut health = HashMap::new();
    health.insert("cpu_usage".to_string(), "42%".to_string());
    health.insert("memory_usage".to_string(), "68%".to_string());
    health.insert("disk_usage".to_string(), "55%".to_string());
    health.insert("network_latency".to_string(), "23ms".to_string());
    health.insert("uptime".to_string(), "15d 7h 32m".to_string());
    health.insert("status".to_string(), "Healthy".to_string());
    health
}
