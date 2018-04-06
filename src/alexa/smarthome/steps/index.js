function buildReportState(req, stateValue) {
    let res = {
        context: {
            properties: [
                {
                    namespace: 'Alexa.PowerController',
                    name: 'powerState',
                    value: stateValue,
                    timeOfSample: new Date(Date.now()).toJSON(),
                    uncertaintyInMilliseconds: 500
                }
            ]
        },
        event: {
            header: {
                namespace: 'Alexa',
                name: 'StateReport',
                payloadVersion: '3',
                messageId: req.directive.header.messageId + '-S',
                correlationToken: req.directive.header.correlationToken
            },
            endpoint: req.directive.endpoint,
            payload: {}
        }
    }

    log('DEBUG: ', ' STATEREPORT: ', JSON.stringify(res))

    return res
}

function log(message, message1, message2) {
    console.log(message + message1 + message2);
}

exports.handler = function (request, context) {
    if (request.directive.header.namespace === 'Alexa.Discovery' && request.directive.header.name === 'Discover') {
        log('DEBUG:', 'Discover request',  JSON.stringify(request));
        handleDiscovery(request, context, '');
    }
    else if (request.directive.header.namespace === 'Alexa.PowerController') {
        if (request.directive.header.name === 'TurnOn' || request.directive.header.name === 'TurnOff') {
            log('DEBUG:', 'TurnOn or TurnOff Request', JSON.stringify(request));
            handlePowerControl(request, context);
        }
    } else if (request.directive.header.namespace === 'Alexa') {
        // This is required to allow Alexa to know the current state of the device
        // It keeps the message 'Server is unreponsive.' from being displayed
        if (request.directive.header.name === 'ReportState') {
            log('DEBUG:', 'ReportState Request ', JSON.stringify(request));
            handleReportState(request, context);
        }
    }
    else {
        log('DEBUG:', 'Unknown request',  JSON.stringify(request));
    }

    function handleDiscovery(request, context) {
        var payload = {
            endpoints:
            [
                {
                    endpointId: 'demo_id',
                    manufacturerName: 'Smart Device Company',
                    friendlyName: 'Bedroom Outlet',
                    description: 'Smart Device Switch',
                    displayCategories: ['SWITCH'],
                    cookie: {
                        key1: 'arbitrary key/value pairs for skill to reference this endpoint.',
                        key2: 'There can be multiple entries',
                        key3: 'but they should only be used for reference purposes.',
                        key4: 'This is not a suitable place to maintain current endpoint state.'
                    },
                    capabilities:
                    [
                        {
                          type: 'AlexaInterface',
                          interface: 'Alexa',
                          version: '3'
                        },
                        {
                            interface: 'Alexa.PowerController',
                            version: '3',
                            type: 'AlexaInterface',
                            properties: {
                                supported: [{
                                    name: 'powerState'
                                }],
                                 retrievable: true
                            }
                        }
                    ]
                }
            ]
        };
        var header = request.directive.header;
        header.name = 'Discover.Response';
        log('DEBUG', 'Discovery Response: ', JSON.stringify({ header: header, payload: payload }));
        context.succeed({ event: { header: header, payload: payload } });
    }

    function handlePowerControl(request, context) {
        // get device ID passed in during discovery
        var requestMethod = request.directive.header.name;
        // get user token pass in request
        var requestToken = request.directive.endpoint.scope.token;
        var powerResult;

        if (requestMethod === 'TurnOn') {

            // Make the call to your device cloud for control 
            // powerResult = stubControlFunctionToYourCloud(endpointId, token, request);
            powerResult = 'ON';
        }
       else if (requestMethod === 'TurnOff') {
            // Make the call to your device cloud for control and check for success 
            // powerResult = stubControlFunctionToYourCloud(endpointId, token, request);
            powerResult = 'OFF';
        }
        var contextResult = {
            properties: [{
                namespace: 'Alexa.PowerController',
                name: 'powerState',
                value: powerResult,
                timeOfSample: '2017-09-03T16:20:50.52Z', //retrieve from result.
                uncertaintyInMilliseconds: 50
            }]
        };
        var response = {
            context: contextResult,
            event: {
                header: {
                    namespace: 'Alexa',
                    name: 'Response',
                    payloadVersion: '3',
                    messageId: request.directive.header.messageId + '-R'
                },
                payload: {}
            },
            endpoint: request.directive.endpoint
        };
        log('DEBUG', 'Alexa.PowerController ', JSON.stringify(response));
        context.succeed(response);
    }

    function handleReportState(request, context) {
        context.succeed(buildReportState(request, 'OFF'))
    }
};
