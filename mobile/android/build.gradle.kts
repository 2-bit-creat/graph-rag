import com.android.build.gradle.LibraryExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Some federated plugins (e.g. desktop_drop 0.5.x) still declare compileSdk 33.
//
// MUST be registered before the evaluationDependsOn block below. That block
// force-evaluates :app while Gradle is still walking the subprojects, so if this
// one came second it would try to add an afterEvaluate callback to a project
// that had already been evaluated — which Gradle 9 rejects outright with
// "Cannot run Project.afterEvaluate(Action) when the project is already
// evaluated", failing the whole Android build.
subprojects {
    afterEvaluate {
        plugins.withId("com.android.library") {
            extensions.configure<LibraryExtension>("android") {
                compileSdk = 36
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
