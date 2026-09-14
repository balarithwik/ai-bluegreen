pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
    }

    parameters {
        choice(
            name: 'DEMO_SCENARIO',
            choices: [
                'ALL_STAGES_PROMOTE',
                'ROLLBACK_AT_POST_VALIDATION'
            ],
            description: 'Blue-Green demo scenario. Scenario intent is never passed to the AI engine.'
        )

        string(
            name: 'REPORT_RECIPIENTS',
            defaultValue: '',
            description: 'Comma-separated email recipients. Leave blank to archive reports without sending email.'
        )
    }

    environment {
        KUBECONFIG = 'C:\\Users\\Bala\\.kube\\config'
        PYTHONIOENCODING = 'utf-8'
        PRE_DECISION = 'NOT_RUN'
        POST_ACTION = 'NOT_RUN'
        DEPLOYMENT_BUILD_ID = ''
        BLUE_RELEASE_ID = ''
        GREEN_RELEASE_ID = ''
    }

    stages {

        stage('01 - Checkout & Fresh Start') {
            steps {
                checkout scm

                script {
                    def releaseTimestamp = powershell(
                        returnStdout: true,
                        script: "(Get-Date -Format 'yyyyMMdd-HHmmss')"
                    ).trim()

                    env.DEPLOYMENT_BUILD_ID = "${releaseTimestamp}-${env.BUILD_NUMBER}"
                    env.BLUE_RELEASE_ID = "blue-${env.DEPLOYMENT_BUILD_ID}"
                    env.GREEN_RELEASE_ID = "green-${env.DEPLOYMENT_BUILD_ID}"

                    currentBuild.displayName = "#${env.BUILD_NUMBER} | ${params.DEMO_SCENARIO}"
                    currentBuild.description = (
                        "Blue ${env.BLUE_RELEASE_ID} -> Green ${env.GREEN_RELEASE_ID}"
                    )

                    echo "Deployment Build ID : ${env.DEPLOYMENT_BUILD_ID}"
                    echo "Blue Release ID     : ${env.BLUE_RELEASE_ID}"
                    echo "Green Release ID    : ${env.GREEN_RELEASE_ID}"
                }

                echo 'Cleaning any previous Blue-Green execution before starting...'

                powershell '''
                    & .\\scripts\\00-cleanup-environment.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                '''

                powershell '''
                    & .\\scripts\\01-precheck.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                '''
            }
        }

        stage('02 - Platform & Monitoring Setup') {
            steps {
                powershell '''
                    & .\\scripts\\02-create-cluster.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\03-install-argo.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\04-install-monitoring.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\15-install-pushgateway.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\17-install-grafana-dashboard.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\18-enable-grafana-anonymous.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\20-open-monitoring-dashboard.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                '''
            }
        }

        stage('03 - Build Blue & Green Images') {
            steps {
                powershell '''
                    & .\\scripts\\05-build-image.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                '''
            }
        }

        stage('04 - Blue Baseline - 10 Users') {
            steps {
                powershell '''
                    & .\\scripts\\06-deploy-blue.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\07-run-blue-baseline.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\16-publish-dashboard-metrics.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    Write-Host "[INFO] Grafana observation hold: 30 seconds"
                    Start-Sleep -Seconds 30
                '''
            }
        }

        stage('05 - Green Preview - 10 Users') {
            steps {
                powershell '''
                    & .\\scripts\\08-deploy-green-preview.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\09-run-green-validation.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\16-publish-dashboard-metrics.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    Write-Host "[INFO] Grafana observation hold: 30 seconds"
                    Start-Sleep -Seconds 30
                '''
            }
        }

        stage('06 - Pre-Promotion AI Analysis') {
            steps {
                script {
                    int aiRc = powershell(
                        returnStatus: true,
                        script: '''
                            & .\\scripts\\10-run-ai-analysis.ps1
                            exit $LASTEXITCODE
                        '''
                    )

                    if (!(aiRc in [0, 3, 4])) {
                        error("Pre-promotion AI analysis failed unexpectedly with exit code ${aiRc}.")
                    }

                    env.PRE_DECISION = powershell(
                        returnStdout: true,
                        script: '''
                            $Decision = Get-Content .\\results\\ai-analysis\\decision.json -Raw | ConvertFrom-Json
                            Write-Output ([string]$Decision.finalDecision)
                        '''
                    ).trim().toUpperCase()

                    echo "Pre-promotion AI decision: ${env.PRE_DECISION}"

                    powershell '''
                        & .\\scripts\\16-publish-dashboard-metrics.ps1
                        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                        Write-Host "[INFO] Grafana observation hold: 30 seconds"
                        Start-Sleep -Seconds 30
                    '''

                    if (env.PRE_DECISION != 'PROMOTE') {
                        currentBuild.result = 'UNSTABLE'
                        echo "Automatic Green promotion blocked by AI/policy decision: ${env.PRE_DECISION}"
                    }
                }
            }
        }

        stage('07 - AI-Approved Green Promotion') {
            when {
                expression { env.PRE_DECISION == 'PROMOTE' }
            }
            steps {
                powershell '''
                    & .\\scripts\\11-promote-green.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\16-publish-dashboard-metrics.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    Write-Host "[INFO] Grafana observation hold after production cutover: 30 seconds"
                    Start-Sleep -Seconds 30
                '''
            }
        }

        stage('08 - Prepare Post-Validation Condition') {
            when {
                expression { env.PRE_DECISION == 'PROMOTE' }
            }
            steps {
                powershell '''
                    & .\\scripts\\11A-prepare-post-validation-condition.ps1 `
                        -Scenario $env:DEMO_SCENARIO
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                '''
            }
        }

        stage('09 - Post-Promotion JMeter - 20 Users') {
            when {
                expression { env.PRE_DECISION == 'PROMOTE' }
            }
            steps {
                powershell '''
                    & .\\scripts\\12-post-promotion-jmeter.ps1 -Threads 20
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    & .\\scripts\\16-publish-dashboard-metrics.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    Write-Host "[INFO] Grafana observation hold after 20-user JMeter validation: 30 seconds"
                    Start-Sleep -Seconds 30
                '''
            }
        }

        stage('10 - Post-Validation AI Analysis') {
            when {
                expression { env.PRE_DECISION == 'PROMOTE' }
            }
            steps {
                script {
                    int postRc = powershell(
                        returnStatus: true,
                        script: '''
                            & .\\scripts\\13-post-validation-ai.ps1
                            exit $LASTEXITCODE
                        '''
                    )

                    if (postRc == 0) {
                        env.POST_ACTION = 'KEEP_GREEN'
                    }
                    else if (postRc == 4) {
                        env.POST_ACTION = 'ROLLBACK_REQUIRED'
                    }
                    else {
                        error("Post-validation AI step failed unexpectedly with exit code ${postRc}.")
                    }

                    echo "Post-validation action: ${env.POST_ACTION}"

                    powershell '''
                        & .\\scripts\\16-publish-dashboard-metrics.ps1
                        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                        Write-Host "[INFO] Grafana observation hold after post-validation AI: 30 seconds"
                        Start-Sleep -Seconds 30
                    '''
                }
            }
        }

        stage('11 - Conditional Rollback To Blue') {
            when {
                expression { env.POST_ACTION == 'ROLLBACK_REQUIRED' }
            }
            steps {
                powershell '''
                    & .\\scripts\\14-rollback-to-blue.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
                '''

                script {
                    env.POST_ACTION = 'ROLLED_BACK_TO_BLUE'
                }

                powershell '''
                    & .\\scripts\\16-publish-dashboard-metrics.ps1
                    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

                    Write-Host "[INFO] Grafana final rollback observation hold: 30 seconds"
                    Start-Sleep -Seconds 30
                '''
            }
        }

        stage('12 - Final Deployment Summary') {
            steps {
                script {
                    echo '============================================================'
                    echo ' AI BLUE-GREEN DEPLOYMENT PIPELINE SUMMARY'
                    echo '============================================================'
                    echo "Scenario             : ${params.DEMO_SCENARIO}"
                    echo "Build ID             : ${env.DEPLOYMENT_BUILD_ID}"
                    echo "Blue Release         : ${env.BLUE_RELEASE_ID}"
                    echo "Green Release        : ${env.GREEN_RELEASE_ID}"
                    echo "Pre-Promotion AI     : ${env.PRE_DECISION}"
                    echo "Post Action          : ${env.POST_ACTION}"

                    if (env.PRE_DECISION != 'PROMOTE') {
                        echo 'Final Production     : BLUE / v1-healthy'
                        echo 'Outcome              : Green promotion safely blocked'
                    }
                    else if (env.POST_ACTION == 'KEEP_GREEN') {
                        echo 'Final Production     : GREEN / v2-healthy'
                        echo 'Outcome              : Green promoted and retained'
                    }
                    else if (env.POST_ACTION == 'ROLLED_BACK_TO_BLUE') {
                        echo 'Final Production     : BLUE / v1-healthy'
                        echo 'Outcome              : Post-validation risk detected; Blue restored'
                    }
                    else {
                        echo 'Final Production     : VERIFY EXECUTION EVIDENCE'
                        echo 'Outcome              : Final deployment action incomplete'
                    }

                    echo '============================================================'
                }
            }
        }
    }

    post {
        always {
            script {
                echo 'Preparing execution evidence before mandatory cleanup...'

                try {
                    int reportRc = powershell(
                        returnStatus: true,
                        script: '''
                            if (Test-Path .\\reporting\\generate_report.py) {
                                python .\\reporting\\generate_report.py
                                exit $LASTEXITCODE
                            }
                            Write-Host "[WARN] reporting\\generate_report.py not found."
                            exit 1
                        '''
                    )

                    if (reportRc != 0) {
                        echo "[WARN] HTML report generation returned exit code ${reportRc}."
                    }

                    int jmeterZipRc = powershell(
                        returnStatus: true,
                        script: '''
                            if (Test-Path .\\scripts\\21-package-jmeter-results.ps1) {
                                & .\\scripts\\21-package-jmeter-results.ps1 `
                                    -BuildNumber $env:BUILD_NUMBER
                                exit $LASTEXITCODE
                            }
                            Write-Host "[WARN] JMeter package script not found."
                            exit 1
                        '''
                    )

                    if (jmeterZipRc != 0) {
                        echo '[INFO] No complete JMeter evidence package was produced for this run.'
                    }

                    archiveArtifacts(
                        artifacts: 'results/**/*,runtime/reports/**/*',
                        allowEmptyArchive: true,
                        fingerprint: true
                    )

                    if (
                        params.REPORT_RECIPIENTS != null &&
                        params.REPORT_RECIPIENTS.trim()
                    ) {
                        try {
                            def emailBody
                            def emailSubject

                            if (fileExists('runtime/reports/ai-bluegreen-email-summary.html')) {
                                emailBody = readFile(
                                    file: 'runtime/reports/ai-bluegreen-email-summary.html'
                                )
                            }
                            else {
                                emailBody = "<html><body style='font-family:Arial,sans-serif'><h2>AI Blue-Green Deployment Pipeline</h2><p>Build #${env.BUILD_NUMBER} completed with status <b>${currentBuild.currentResult}</b>.</p><p>The detailed HTML summary could not be generated. Review the archived Jenkins execution evidence.</p></body></html>"
                            }

                            if (fileExists('runtime/reports/email-metadata.json')) {
                                emailSubject = powershell(
                                    returnStdout: true,
                                    script: '''
                                        $Meta = Get-Content .\\runtime\\reports\\email-metadata.json -Raw | ConvertFrom-Json
                                        Write-Output ([string]$Meta.subject)
                                    '''
                                ).trim()
                            }
                            else {
                                emailSubject = (
                                    "AI Blue-Green Deployment | " +
                                    "${currentBuild.currentResult} | " +
                                    "${params.DEMO_SCENARIO} | " +
                                    "Build #${env.BUILD_NUMBER}"
                                )
                            }

                            def attachments = []

                            if (fileExists('runtime/reports/ai-bluegreen-deployment-report.html')) {
                                attachments.add('runtime/reports/ai-bluegreen-deployment-report.html')
                            }

                            def zipName = "runtime/reports/ai-bluegreen-jmeter-results-build-${env.BUILD_NUMBER}.zip"
                            if (fileExists(zipName)) {
                                attachments.add(zipName)
                            }

                            if (attachments.size() > 0) {
                                emailext(
                                    to: params.REPORT_RECIPIENTS.trim(),
                                    subject: emailSubject,
                                    mimeType: 'text/html',
                                    body: emailBody,
                                    attachmentsPattern: attachments.join(',')
                                )
                            }
                            else {
                                emailext(
                                    to: params.REPORT_RECIPIENTS.trim(),
                                    subject: emailSubject,
                                    mimeType: 'text/html',
                                    body: emailBody
                                )
                            }

                            echo "Report email sent to: ${params.REPORT_RECIPIENTS}"
                        }
                        catch (mailError) {
                            echo "[WARN] Email delivery failed: ${mailError.message}"
                        }
                    }
                    else {
                        echo '[INFO] REPORT_RECIPIENTS is empty. Reports archived in Jenkins; email skipped.'
                    }
                }
                catch (evidenceError) {
                    echo "[WARN] Evidence/report handling encountered an error: ${evidenceError.message}"
                }
                finally {
                    echo 'Running mandatory full environment cleanup...'

                    int cleanupRc

                    if (fileExists('scripts/00-cleanup-environment.ps1')) {
                        cleanupRc = powershell(
                            returnStatus: true,
                            script: '''
                                & .\\scripts\\00-cleanup-environment.ps1
                                exit $LASTEXITCODE
                            '''
                        )
                    }
                    else {
                        cleanupRc = powershell(
                            returnStatus: true,
                            script: '''
                                Write-Host "[WARN] Cleanup script unavailable; using emergency cluster cleanup."
                                kind delete cluster --name ai-bluegreen
                                exit 0
                            '''
                        )
                    }

                    if (cleanupRc != 0) {
                        echo "[WARN] Mandatory cleanup returned exit code ${cleanupRc}."
                        if (currentBuild.currentResult == 'SUCCESS') {
                            currentBuild.result = 'UNSTABLE'
                        }
                    }
                    else {
                        echo 'Mandatory full cleanup completed.'
                    }
                }
            }
        }

        success {
            echo 'AI Blue-Green deployment pipeline completed successfully.'
        }

        unstable {
            echo 'AI Blue-Green deployment completed with a safe policy block or cleanup warning.'
        }

        failure {
            echo 'AI Blue-Green deployment pipeline failed. Evidence was archived and cleanup was attempted.'
        }

        aborted {
            echo 'AI Blue-Green deployment pipeline was aborted. Mandatory cleanup was still executed.'
        }
    }
}
