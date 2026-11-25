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
        // moqserver's Kotlin test client is published through JitPack, pinned by commit.
        maven("https://jitpack.io") {
            content {
                includeGroup("com.github.ArjangConsulting")
            }
        }
    }
}

rootProject.name = "ExampleApp"

include(":app")
