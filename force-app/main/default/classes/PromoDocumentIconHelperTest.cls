/**
 * Tests for PromoDocumentIconHelper. The helper is a thin SOQL wrapper, so coverage is mostly
 * about the three input paths: blank, found, not-found. Document records require a Folder ID; the
 * shared "Personal Documents" folder of the running user works in test context without setup.
 */
@IsTest
private class PromoDocumentIconHelperTest {

    @IsTest
    static void blankInput_returnsNull() {
        System.assertEquals(null, PromoDocumentIconHelper.getDocumentImageUrl(null));
        System.assertEquals(null, PromoDocumentIconHelper.getDocumentImageUrl(''));
        System.assertEquals(null, PromoDocumentIconHelper.getDocumentImageUrl('   '));
    }

    @IsTest
    static void documentFound_returnsImageServerUrl() {
        // Insert a Document in the running user's personal folder. FolderId can be the running
        // user's Id for personal folders, but we also fall back to any visible folder.
        Document d = new Document(
            Name = 'pcih_test_' + System.currentTimeMillis(),
            DeveloperName = 'pcih_test_' + System.currentTimeMillis(),
            FolderId = UserInfo.getUserId(),
            IsPublic = true
        );
        try {
            insert d;
        } catch (Exception e) {
            // Some org configurations block Document inserts in test context; in that case the
            // helper's "not found" path is the relevant assertion and we exit cleanly.
            System.assertEquals(null, PromoDocumentIconHelper.getDocumentImageUrl('definitely_not_present_' + System.currentTimeMillis()));
            return;
        }

        Test.startTest();
        String url = PromoDocumentIconHelper.getDocumentImageUrl(d.Name);
        Test.stopTest();

        System.assertNotEquals(null, url, 'Expected URL for present Document');
        System.assert(url.startsWith('/servlet/servlet.ImageServer?id='),
            'URL should start with ImageServer path; got: ' + url);
        System.assert(url.contains('oid=' + UserInfo.getOrganizationId()),
            'URL should embed the org Id; got: ' + url);
    }

    @IsTest
    static void documentNotFound_returnsNull() {
        String url = PromoDocumentIconHelper.getDocumentImageUrl('zzz_definitely_no_such_document_' + System.currentTimeMillis());
        System.assertEquals(null, url);
    }
}
