plugins {
    id("org.jetbrains.kotlin.jvm")
    id("org.jetbrains.kotlin.plugin.serialization")
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    // 跨平台测试向量在仓库根目录的 spec/test-vectors。
    systemProperty("riji.vectors", rootProject.projectDir.resolve("../spec/test-vectors").canonicalPath)
}
