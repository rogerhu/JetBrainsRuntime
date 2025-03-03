/*
 * Copyright 2000-2021 JetBrains s.r.o.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.jetbrains.base;

import com.jetbrains.internal.JBRApi;

import java.lang.invoke.MethodHandles;

/**
 * This class contains mapping between JBR API interfaces and implementation in {@code java.base} module.
 */
public class JBRApiModule {
    static {
        JBRApi.registerModule(MethodHandles.lookup(), JBRApiModule.class.getModule()::addExports)
                .service("com.jetbrains.JBR$ServiceApi")
                    .withStatic("getService", "getService", "com.jetbrains.internal.JBRApi");
    }
}
