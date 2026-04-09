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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

fun Project.applyNamespaceFallback() {
    val androidExtension = extensions.findByName("android") ?: return
    val extensionClass = androidExtension::class.java
    val getNamespace = extensionClass.methods.find { it.name == "getNamespace" }
    val setNamespace = extensionClass.methods.find { it.name == "setNamespace" }
    val currentNamespace = getNamespace?.invoke(androidExtension) as? String

    if (currentNamespace.isNullOrBlank()) {
        setNamespace?.invoke(androidExtension, group.toString())
    }
}

subprojects {
    plugins.withId("com.android.application") {
        applyNamespaceFallback()
    }
    plugins.withId("com.android.library") {
        applyNamespaceFallback()
    }
}
