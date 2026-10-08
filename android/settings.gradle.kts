// 日迹 Android：core 是纯 Kotlin 内核（同步协议、模型、每日规则），app 是 Compose 界面。
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "riji"
include(":core")
