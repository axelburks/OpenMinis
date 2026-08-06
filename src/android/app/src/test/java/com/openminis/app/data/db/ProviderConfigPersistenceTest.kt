package com.openminis.app.data.db

import com.openminis.app.data.model.ProviderConfig
import com.openminis.app.data.model.ProviderCredential
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.data.model.ProviderType
import kotlinx.serialization.json.Json
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class ProviderConfigPersistenceTest {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        coerceInputValues = true
    }

    @Test
    fun testProviderRequestCustomization_usesSingleEnvelopeRoundTrip_BitsUT() {
        val provider = ProviderInstance(
            id = "provider",
            label = "Provider",
            providerType = ProviderType.openAI,
            credentialType = ProviderCredential.apiKey,
            customRequestHeaders = listOf(
                """X-Test = "value"""",
                "Authorization = {{ provider.apiKey }}",
            ),
            customRequestBody = listOf(
                """metadata.source = "provider"""",
                "stream = false",
            ),
        )
        val snapshot = ProviderConfig(
            instances = mutableListOf(provider),
        ).toSnapshot(json)

        val row = snapshot.instances.single()
        val envelope = JSONObject(row.requestCustomizationJson!!)
        assertEquals(2, envelope.length())
        assertEquals("X-Test = \"value\"", envelope.getJSONArray("headers").getString(0))
        assertEquals("metadata.source = \"provider\"", envelope.getJSONArray("body").getString(0))

        val loaded = snapshot.toProviderConfig(json).instances.single()
        assertEquals(provider.customRequestHeaders, loaded.customRequestHeaders)
        assertEquals(provider.customRequestBody, loaded.customRequestBody)
    }

    @Test
    fun testProviderRequestCustomization_emptyEnvelopeStoresNull_BitsUT() {
        val provider = ProviderInstance(
            id = "provider",
            label = "Provider",
            providerType = ProviderType.openAI,
            credentialType = ProviderCredential.apiKey,
        )

        val row = ProviderConfig(
            instances = mutableListOf(provider),
        ).toSnapshot(json).instances.single()

        assertNull(row.requestCustomizationJson)
    }

    @Test
    fun testProviderInstanceEntity_doesNotRetainLegacyCustomUserAgent_BitsUT() {
        val fieldNames = ProviderInstanceEntity::class.java.declaredFields
            .map { it.name }
            .toSet()

        assertFalse(
            "Provider schema must not retain the removed custom_user_agent field",
            "customUserAgent" in fieldNames,
        )
    }
}
